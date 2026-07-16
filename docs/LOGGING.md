# Claude Gateway — Logging & Observability

**Last updated:** 2026-07-15  
**Status:** ✅ Fully operational

---

## Quick Reference

| Feature | Status |
|---|---|
| Inference events (model, user, status, latency) | ✅ |
| Surface detection (code / cowork / cli / desktop-webview) | ✅ nginx map |
| User identification (email from OIDC) | ✅ |
| Request tracing (UUID per request, cross-stream) | ✅ |
| Loki storage (7-day retention) | ✅ |
| Grafana dashboard (11 panels) | ✅ |
| Log push interval | 30 seconds |

---

## Architecture

```
Claude Desktop / CLI
  ↓  HTTPS  User-Agent header
ALB :443
  ↓
nginx-access-log :8080      ← logs surface + User-Agent per request
  ↓  proxy_pass
ttl-proxy :8082              ← strips cache_control.ttl for Claude 3.x APAC
  ↓  proxy_pass
Gateway :8081                ← logs inference events (stdout JSON)
  ↓
log-forwarder pod            ← reads both containers via K8S API every 30s
  ↓  HTTP POST
Loki :3100                   ← stores 7 days, queryable
  ↓
Grafana :3000                ← https://ALB/grafana  (admin / <GRAFANA_PASSWORD>)
```

---

## Two Loki Streams

### `{job="gateway-access"}` — nginx access log

Every HTTP request through nginx. Use this for surface/tool breakdown.

```json
{
  "ts": "2026-07-14T07:26:56+00:00",
  "request_id": "a6cb6e3b-8f72-4151-88a0-09a59cf004b2",
  "method": "POST",
  "path": "/v1/messages",
  "status": 200,
  "user_agent": "claude-cli/2.1.205 (external, local-agent, agent-sdk/0.3.205)",
  "surface": "cowork",
  "upstream_ms": "1.986"
}
```

### `{job="claude-gateway"}` — gateway inference events

Every inference request with user identity and model. Use this for usage analytics.

```json
{
  "ts": "2026-07-14T07:26:55.728Z",
  "evt": "inference",
  "request_id": "a6cb6e3b-8f72-4151-88a0-09a59cf004b2",
  "email": "user@yourcompany.com",
  "path": "/v1/messages",
  "model": "claude-sonnet-4-6",
  "upstream": "bedrock",
  "status": 200,
  "ms": 1566
}
```

Cross-reference the two streams by `request_id`.

---

## Field Reference

### gateway-access fields

| Field | Type | Example | Notes |
|---|---|---|---|
| `ts` | ISO 8601 | `2026-07-14T07:26:56+00:00` | nginx timestamp |
| `request_id` | UUID | `a6cb6e3b-...` | Matches gateway-access request_id |
| `method` | string | `POST` | HTTP method |
| `path` | string | `/v1/messages` | API path |
| `status` | int | `200` | HTTP status |
| `user_agent` | string | `claude-cli/2.1.205...` | Full UA string |
| `surface` | string | `cowork` | Detected surface (see below) |
| `upstream_ms` | float | `1.986` | nginx upstream response time (seconds) |

### claude-gateway fields

| Field | Type | Example | Notes |
|---|---|---|---|
| `ts` | ISO 8601 | `2026-07-14T07:26:55.728Z` | Gateway timestamp |
| `evt` | string | `inference` | `inference` \| `auth.denied` \| `session.mint` |
| `request_id` | UUID | `a6cb6e3b-...` | Matches gateway-access request_id |
| `email` | string | `user@yourcompany.com` | From OIDC token |
| `path` | string | `/v1/messages` | API endpoint |
| `model` | string | `claude-sonnet-4-6` | Gateway model alias |
| `upstream` | string | `bedrock` | Backend |
| `status` | int | `200` | HTTP status |
| `ms` | int | `1566` | Gateway latency (ms) |
| `sub` | string | `Cg1wb2Mtd...` | OIDC subject ID (base64) |

---

## Surface Detection

nginx identifies the surface from the User-Agent header using a `map` block.

| User-Agent | surface | Description |
|---|---|---|
| `claude-cli/X (external, claude-desktop-3p)` | `code` | Desktop Code tab |
| `claude-cli/X (external, local-agent, agent-sdk/X)` | `cowork` | Desktop Cowork tasks |
| `claude-cli/X` | `cli` | Terminal Claude Code CLI |
| `Claude for Desktop/X (chat)` | `chat` | Desktop Chat (explicit UA) |
| `Claude for Desktop/X (code)` | `code` | Desktop Code (explicit UA) |
| `Claude for Desktop/X (cowork)` | `cowork` | Desktop Cowork (explicit UA) |
| `Mozilla/X AppleWebKit/X` | `desktop-webview` | Desktop Chat/Cowork webview |
| `ELB-HealthChecker/2.0` | `healthcheck` | ALB probe |
| anything else | `unknown` | API clients, scripts |

**Note:** Desktop Chat sends `Mozilla/5.0 AppleWebKit` — it cannot be distinguished from the Cowork webview at the HTTP layer. Both appear as `desktop-webview`. Desktop Code and Cowork _tasks_ are identifiable via the `claude-cli` UA.

---

## Loki Queries

### Core queries

```logql
# All inference requests (exclude healthchecks)
{job="gateway-access"} | json | path="/v1/messages" | surface != "healthcheck"

# All inference events with user context
{job="claude-gateway"} | json | evt="inference"
```

### By surface

```logql
{job="gateway-access"} | json | surface="code"
{job="gateway-access"} | json | surface="cowork"
{job="gateway-access"} | json | surface="cli"
{job="gateway-access"} | json | surface="desktop-webview"
```

### By user

```logql
{job="claude-gateway"} | json | email="user@yourcompany.com"
```

### By model

```logql
{job="claude-gateway"} | json | model="claude-sonnet-4-6"
{job="claude-gateway"} | json | model=~".*apac.*"
```

### Aggregations

```logql
# Requests per user (5-min buckets)
sum by (email)(count_over_time({job="claude-gateway"} | json | evt="inference" [5m]))

# Requests by surface (last 1h)
sum by (surface)(count_over_time({job="gateway-access"} | json | path="/v1/messages" [1h]))

# Requests by model per user (last 1h)
sum by (email, model)(count_over_time({job="claude-gateway"} | json | evt="inference" [1h]))

# Average latency by surface
avg by (surface)(
  {job="gateway-access"} | json | path="/v1/messages" | surface != "healthcheck"
  | unwrap upstream_ms [5m]
)

# Error rate
sum(count_over_time({job="claude-gateway"} | json | evt="inference" | status > 399 [5m]))
/ sum(count_over_time({job="claude-gateway"} | json | evt="inference" [5m])) * 100
```

### Cross-stream join by request_id

```logql
# Find gateway details for a specific access log request
{job="claude-gateway"} | json | request_id="a6cb6e3b-8f72-4151-88a0-09a59cf004b2"
```

---

## Grafana Dashboard

URL: `https://<gateway-hostname>/grafana/d/claude-gw-usage/`  
Credentials: `admin` / `<GRAFANA_PASSWORD>`  
File: `Terraform/modules/claude-gateway/grafana-dashboard.json`

### Panels

| # | Title | Type | Query |
|---|---|---|---|
| 1 | Complete Logs | Logs | `{job="gateway-access"} \| json \| path="/v1/messages" \| surface != "healthcheck"` + inference stream |
| 2 | Total Requests | Stat | `sum(count_over_time({job="claude-gateway"} \| json \| evt="inference" [5m]))` |
| 3 | Avg Latency | Stat | `avg(avg_over_time({job="claude-gateway"} \| json \| evt="inference" \| unwrap ms [5m]))` |
| 4 | Active Users | Stat | `count(sum by (email)(count_over_time(...)))` |
| 5 | Error Rate | Stat | errors/total × 100 |
| 6 | Requests per User (time) | Timeseries | `sum by (email)(count_over_time(... [5m]))` |
| 7 | Requests per User (total) | Pie | `sum by (email)(count_over_time(... [1h]))` |
| 8 | Models per User | Bar chart | `sum by (email, model)(count_over_time(... [1h]))` |
| 9 | Models per User | Table | Same as #8 |
| 10 | Tool / Surface breakdown | Donut | `sum by (surface)(count_over_time(... [1h]))` |
| 11 | Tool Usage Over Time | Timeseries | `sum by (surface)(count_over_time(... [5m]))` |

**Dashboard quirks (Grafana 11.1 + Loki 3.1):**
- Use `[5m]` or `[1h]` explicit windows — NOT `instant=true + [$__range]` (unreliable)
- Avg Latency must be `avg(avg_over_time(...))` — without outer `avg()` each log line = separate series

---

## Real-time Log Tailing

```bash
# Inference events
kubectl logs -n claude-system deployment/claude-gateway -c claude-gateway -f

# Surface / User-Agent access log
kubectl logs -n claude-system deployment/claude-gateway -c nginx-access-log -f

# Log-forwarder push status
kubectl logs -n claude-system deployment/log-forwarder -f
```

---

## Troubleshooting

### No logs in Loki

```bash
# 1. Check log-forwarder is pushing
kubectl logs -n claude-system -l app=log-forwarder | grep "pushed"
# Expect: "[2026-07-14T...] claude-gateway: pushed N new lines"

# 2. Check Loki is ready
kubectl exec -n claude-system deployment/loki -- wget -qO- http://127.0.0.1:3100/ready

# 3. Test push directly
kubectl exec -n claude-system deployment/loki -- sh -c '
  TS=$(date +%s%N)
  wget -qO- --post-data="{\"streams\":[{\"stream\":{\"job\":\"test\"},\"values\":[[\"$TS\",\"test\"]]}]}" \
  --header="Content-Type: application/json" http://127.0.0.1:3100/loki/api/v1/push && echo "push OK"
'
```

### surface="unknown" for all requests

The nginx ConfigMap points to 8082 (ttl-proxy) not directly to 8081. Verify:
```bash
kubectl exec -n claude-system deployment/claude-gateway -c nginx-access-log -- \
  grep proxy_pass /etc/nginx/nginx.conf
# Must show: proxy_pass http://127.0.0.1:8082;
```

### Logs showing duplicate entries in Loki

The log-forwarder uses `sinceTime=` cursor — duplicates happen only on pod restart (small gap). Check:
```bash
kubectl logs -n claude-system deployment/log-forwarder | grep "new lines"
# Each cycle should say "pushed N new lines" not same count repeatedly
```

### gateway-access stream missing

```bash
# Check nginx is proxying to ttl-proxy (port 8082)
kubectl exec -n claude-system deployment/claude-gateway -c nginx-access-log -- \
  nginx -t

# Check ttl-proxy is running on 8082
kubectl exec -n claude-system deployment/claude-gateway -c ttl-proxy -- \
  python3 -c "import socket; s=socket.socket(); s.connect(('127.0.0.1',8082)); print('OK')"
```

---

## References

- **ARCHITECTURE.md** — full system diagram, pod layout, network design
- **RUNBOOK.md** — operational procedures, day-2 ops
- **Loki docs:** https://grafana.com/docs/loki/latest/
- **LogQL:** https://grafana.com/docs/loki/latest/query/
- **Claude Code monitoring:** https://code.claude.com/docs/en/monitoring-usage
