#!/usr/bin/env bash
# Switch Claude Code CLI from direct Bedrock to the Claude Apps Gateway.
#
# What this script does:
#   1. Fetches and trusts the self-signed gateway certificate (one-time)
#   2. Writes managed-settings.json to force gateway login
#   3. Strips Bedrock env vars from ~/.claude/settings.json
#   4. Runs `claude /login` to authenticate via your OIDC provider
#
# To revert: run scripts/switch-claude-code-to-bedrock.sh
#
# References:
#   https://docs.anthropic.com/en/docs/claude-code/claude-apps-gateway

set -euo pipefail

# ─── CONFIGURATION — edit before running ─────────────────────────────────────
GATEWAY_URL="https://REPLACE_WITH_YOUR_GATEWAY_HOSTNAME"
# ─────────────────────────────────────────────────────────────────────────────

MANAGED_SETTINGS="/Library/Application Support/ClaudeCode/managed-settings.json"
CERT_PATH="$HOME/claude-gateway.pem"
SETTINGS="$HOME/.claude/settings.json"

die()     { echo "ERROR: $*" >&2; exit 1; }
require() { command -v "$1" &>/dev/null || die "'$1' not found — install it first."; }

require claude
require python3

# ─── 1. Fetch and trust self-signed cert ─────────────────────────────────────
echo "==> Trusting gateway certificate..."

GATEWAY_HOST="${GATEWAY_URL#https://}"
LIVE_CERT=$(echo Q | openssl s_client \
    -connect "${GATEWAY_HOST}:443" \
    -servername "${GATEWAY_HOST}" \
    -timeout 10 2>/dev/null | openssl x509 2>/dev/null || true)

[[ -n "$LIVE_CERT" ]] || die "Could not reach gateway at ${GATEWAY_URL}. Check GATEWAY_URL."
echo "$LIVE_CERT" > "$CERT_PATH"

if security find-certificate -c "claude-gateway" /Library/Keychains/System.keychain &>/dev/null; then
    echo "    Certificate already trusted — skipping."
else
    sudo security add-trusted-cert -d -r trustRoot \
        -k /Library/Keychains/System.keychain "$CERT_PATH"
    echo "    Certificate added to System Keychain."
fi

# ─── 2. Write managed-settings.json ──────────────────────────────────────────
echo "==> Writing Claude Code managed settings..."
sudo mkdir -p "$(dirname "$MANAGED_SETTINGS")"
sudo tee "$MANAGED_SETTINGS" > /dev/null <<JSON
{
  "forceLoginMethod": "gateway",
  "forceLoginGatewayUrl": "${GATEWAY_URL}"
}
JSON
echo "    Written to: $MANAGED_SETTINGS"

# ─── 3. Strip Bedrock env vars from ~/.claude/settings.json ──────────────────
echo "==> Removing Bedrock env vars from ~/.claude/settings.json..."

python3 - "$SETTINGS" <<'PY'
import json, sys

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

env = data.get("env", {})
removed = []
for key in ["CLAUDE_CODE_USE_BEDROCK", "AWS_REGION", "AWS_BEARER_TOKEN_BEDROCK", "ANTHROPIC_MODEL"]:
    if key in env:
        del env[key]
        removed.append(key)

if not env:
    data.pop("env", None)

with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

if removed:
    print(f"    Removed: {', '.join(removed)}")
else:
    print("    No Bedrock env vars found — already clean.")
PY

# ─── 4. Log in via gateway ────────────────────────────────────────────────────
echo ""
echo "==> Logging in to Claude Gateway..."
echo "    A browser window will open to your OIDC provider."
echo ""

claude /login

echo ""
echo "==> Done! Claude Code is now routing through the gateway."
echo "    Verify with: claude -p 'Say hello'"
echo ""
echo "    To revert to direct Bedrock: ./scripts/switch-claude-code-to-bedrock.sh"
