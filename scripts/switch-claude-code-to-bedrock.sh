#!/usr/bin/env bash
# Switch Claude Code CLI back to direct Bedrock (removes gateway config)
#
# Reverses switch-claude-code-to-gateway.sh:
#   1. Removes managed-settings.json (gateway login force)
#   2. Restores Bedrock env vars in ~/.claude/settings.json
set -euo pipefail

MANAGED_SETTINGS="/Library/Application Support/ClaudeCode/managed-settings.json"
SETTINGS="$HOME/.claude/settings.json"

die() { echo "ERROR: $*" >&2; exit 1; }
require() { command -v "$1" &>/dev/null || die "'$1' not found — install it first."; }

require python3

# ─── 1. Remove managed-settings.json ─────────────────────────────────────────
echo "==> Removing Claude Code managed settings (gateway config)..."

if [ -f "$MANAGED_SETTINGS" ]; then
  sudo rm -f "$MANAGED_SETTINGS"
  echo "    Removed: $MANAGED_SETTINGS"
else
  echo "    Not found — already removed."
fi

# ─── 2. Restore Bedrock env vars in ~/.claude/settings.json ──────────────────
echo "==> Restoring Bedrock env vars in ~/.claude/settings.json..."

[ -f "$SETTINGS" ] || die "$SETTINGS not found."

python3 - "$SETTINGS" <<'PY'
import json, sys

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

bedrock_env = {
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "AWS_REGION": "us-east-1",
    "AWS_BEARER_TOKEN_BEDROCK": "<YOUR_AWS_BEARER_TOKEN_BEDROCK>",
    "ANTHROPIC_MODEL": "us.anthropic.claude-sonnet-4-6",
}

env = data.setdefault("env", {})
env.update(bedrock_env)

with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print(f"    Restored: {', '.join(bedrock_env.keys())}")
PY

echo ""
echo "==> Done! Claude Code is back to direct Bedrock."
echo "    Verify with: claude -p 'Say hello'"
echo ""
echo "    To switch to gateway: ./scripts/switch-claude-code-to-gateway.sh"
