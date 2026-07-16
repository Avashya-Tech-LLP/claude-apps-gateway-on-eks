#!/usr/bin/env python3
"""
Log forwarder: reads claude-gateway pod logs via Kubernetes API and pushes to Loki.
Uses a cursor (last seen timestamp) per container to avoid re-pushing duplicates.

Two Loki streams:
  {job=claude-gateway}  - gateway inference events (from claude-gateway container)
  {job=gateway-access}  - nginx access log with surface detection (from nginx-access-log container)
"""
import os
import time
import json
import http.client
import ssl
import urllib.request
from datetime import datetime, timezone

LOKI_HOST = os.getenv("LOKI_HOST", "loki")
LOKI_PORT = int(os.getenv("LOKI_PORT", 3100))
LOKI_PATH = "/loki/api/v1/push"
POLL_INTERVAL = 30

K8S_API_URL = "https://kubernetes.default.svc.cluster.local"
K8S_TOKEN_PATH = "/run/secrets/kubernetes.io/serviceaccount/token"
K8S_NAMESPACE = "claude-system"

try:
    with open(K8S_TOKEN_PATH) as f:
        K8S_TOKEN = f.read().strip()
except Exception as e:
    print(f"Error reading K8S token: {e}")
    K8S_TOKEN = None

# Cursor: last ingested timestamp per container (RFC3339 string for sinceTime param)
cursors = {}


def k8s_request(path):
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request(f"{K8S_API_URL}{path}")
    req.add_header("Authorization", f"Bearer {K8S_TOKEN}")
    with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
        return json.loads(r.read())


def get_pod_logs(pod_name, container, since_time=None):
    """Fetch only new logs since last cursor."""
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        params = f"container={container}&timestamps=true"
        if since_time:
            params += f"&sinceTime={urllib.parse.quote(since_time)}"
        else:
            params += "&tailLines=50"  # bootstrap: last 50 on first run
        url = f"{K8S_API_URL}/api/v1/namespaces/{K8S_NAMESPACE}/pods/{pod_name}/log?{params}"
        req = urllib.request.Request(url)
        req.add_header("Authorization", f"Bearer {K8S_TOKEN}")
        with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
            return r.read().decode("utf-8", errors="ignore")
    except Exception as e:
        print(f"[{now()}] Error fetching logs for {pod_name}/{container}: {e}")
        return ""


def find_gateway_pod():
    try:
        pods = k8s_request(f"/api/v1/namespaces/{K8S_NAMESPACE}/pods")
        for item in pods.get("items", []):
            if item["metadata"].get("labels", {}).get("app") == "claude-gateway":
                if item.get("status", {}).get("phase") == "Running":
                    return item["metadata"]["name"]
    except Exception as e:
        print(f"[{now()}] Pod lookup error: {e}")
    return None


def parse_lines_with_timestamps(raw):
    """
    K8s log lines with timestamps=true have format:
      2026-07-14T07:03:08.123456789Z {"ts":"...","evt":"inference",...}
    Returns list of (rfc3339_ts, log_line) tuples, newest cursor.
    """
    entries = []
    last_ts = None
    for line in raw.splitlines():
        if not line.strip():
            continue
        # First token is the RFC3339 timestamp added by k8s
        parts = line.split(" ", 1)
        if len(parts) == 2:
            ts_str, log_body = parts
            entries.append((ts_str, log_body))
            last_ts = ts_str
        else:
            # No timestamp prefix — push as-is
            entries.append((None, line))
    return entries, last_ts


def push_to_loki(entries, job_label):
    """Push list of (ts_str, line) to Loki."""
    if not entries:
        return 0

    values = []
    base_ns = int(time.time() * 1e9)
    for i, (ts_str, line) in enumerate(entries):
        if not line.strip():
            continue
        # Use k8s timestamp converted to nanoseconds if available
        if ts_str:
            try:
                dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
                ns = int(dt.timestamp() * 1e9)
            except Exception:
                ns = base_ns + i
        else:
            ns = base_ns + i
        values.append([str(ns), line])

    if not values:
        return 0

    payload = {
        "streams": [{
            "stream": {"job": job_label, "namespace": K8S_NAMESPACE, "app": "claude-gateway"},
            "values": values,
        }]
    }

    try:
        conn = http.client.HTTPConnection(LOKI_HOST, LOKI_PORT, timeout=5)
        body = json.dumps(payload)
        conn.request("POST", LOKI_PATH, body, {"Content-Type": "application/json"})
        resp = conn.getresponse()
        body_err = resp.read().decode("utf-8", errors="ignore")[:200]
        conn.close()
        if resp.status in (200, 204):
            return len(values)
        print(f"[{now()}] Loki HTTP {resp.status} for {job_label}: {body_err}")
        return -1  # -1 = do NOT advance cursor (retry next cycle)
    except Exception as e:
        print(f"[{now()}] Push error for {job_label}: {e}")
        return -1  # -1 = do NOT advance cursor


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def loki_ready():
    """Return True if Loki /ready endpoint returns 200."""
    try:
        conn = http.client.HTTPConnection(LOKI_HOST, LOKI_PORT, timeout=3)
        conn.request("GET", "/ready")
        resp = conn.getresponse()
        body = resp.read()  # must read before close
        conn.close()
        return resp.status == 200
    except Exception:
        return False


def process_container(pod_name, container, job_label):
    """Fetch new logs only, push to Loki, update cursor only on success."""
    cursor_key = f"{pod_name}/{container}"
    since = cursors.get(cursor_key)

    raw = get_pod_logs(pod_name, container, since_time=since)
    if not raw:
        return 0

    entries, last_ts = parse_lines_with_timestamps(raw)

    # Skip entries at or before cursor (sinceTime is inclusive, so last line may repeat)
    if since and entries:
        # Drop the first entry if its timestamp equals cursor (it was already ingested)
        if entries[0][0] == since:
            entries = entries[1:]

    count = push_to_loki(entries, job_label)
    if count > 0:
        print(f"[{now()}] {job_label}: pushed {count} new lines")
        if last_ts:
            cursors[cursor_key] = last_ts  # advance cursor only on success
    # count == -1 means Loki rejected — cursor NOT advanced, will retry next cycle
    return count


def main():
    global urllib
    import urllib.parse

    print(f"[{now()}] Log forwarder started (cursor-based, no duplicates)")
    print("  Stream 1: {job=claude-gateway}  — inference events")
    print("  Stream 2: {job=gateway-access}  — nginx surface/UA log")

    cycle = 0
    while True:
        try:
            # Check Loki is ready before pushing — skip cycle if not
            if not loki_ready():
                if cycle % 5 == 0:
                    print(f"[{now()}] Loki not ready — skipping cycle {cycle}")
                cycle += 1
                time.sleep(POLL_INTERVAL)
                continue

            pod = find_gateway_pod()
            if pod:
                process_container(pod, "claude-gateway", "claude-gateway")
                process_container(pod, "nginx-access-log", "gateway-access")
            else:
                if cycle % 10 == 0:
                    print(f"[{now()}] No running gateway pod (cycle {cycle})")
            cycle += 1
        except KeyboardInterrupt:
            break
        except Exception as e:
            print(f"[{now()}] Error: {e}")
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
