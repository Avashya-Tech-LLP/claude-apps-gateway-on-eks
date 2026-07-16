#!/usr/bin/env bash
# Backup all Claude config files (Desktop + Code CLI) to a timestamped directory.
# Run before making changes. Use restore-claude-config.sh to revert.
set -euo pipefail

BACKUP_ROOT="${CLAUDE_GATEWAY_REPO:-$HOME/claude-apps-gateway-on-eks}/backups/claude-config"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"

echo "==> Creating backup at: ${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}"

backup_file() {
  local src="$1"
  local label="$2"
  local dest="${BACKUP_DIR}/${label}"
  if [ -f "$src" ]; then
    cp "$src" "$dest"
    echo "    ✓ $label"
  else
    echo "    - $label (not found — skipped)"
  fi
}

backup_dir() {
  local src="$1"
  local label="$2"
  local dest="${BACKUP_DIR}/${label}"
  if [ -d "$src" ]; then
    cp -r "$src" "$dest"
    echo "    ✓ $label/"
  else
    echo "    - $label/ (not found — skipped)"
  fi
}

# ─── Claude Desktop: managed plist (gateway config, requires sudo to read) ───
echo ""
echo "--- Claude Desktop managed preferences ---"
sudo cp "/Library/Managed Preferences/com.anthropic.claudefordesktop.plist" \
  "${BACKUP_DIR}/managed_com.anthropic.claudefordesktop.plist" 2>/dev/null \
  && echo "    ✓ managed_com.anthropic.claudefordesktop.plist" \
  || echo "    - managed plist (not found — skipped)"

# ─── Claude Desktop: user preferences plist ──────────────────────────────────
echo ""
echo "--- Claude Desktop user preferences ---"
backup_file \
  "${HOME}/Library/Preferences/com.anthropic.claudefordesktop.plist" \
  "user_com.anthropic.claudefordesktop.plist"

# ─── Claude Desktop: app config (Claude — standard) ─────────────────────────
echo ""
echo "--- Claude Desktop app config (standard) ---"
backup_file \
  "${HOME}/Library/Application Support/Claude/claude_desktop_config.json" \
  "Claude_claude_desktop_config.json"
backup_file \
  "${HOME}/Library/Application Support/Claude/config.json" \
  "Claude_config.json"

# ─── Claude Desktop: app config (Claude-3p — gateway/3rd-party mode) ─────────
echo ""
echo "--- Claude Desktop app config (3p/gateway mode) ---"
backup_file \
  "${HOME}/Library/Application Support/Claude-3p/claude_desktop_config.json" \
  "Claude-3p_claude_desktop_config.json"
backup_file \
  "${HOME}/Library/Application Support/Claude-3p/config.json" \
  "Claude-3p_config.json"
backup_file \
  "${HOME}/Library/Application Support/Claude-3p/developer_settings.json" \
  "Claude-3p_developer_settings.json"

# ─── Claude Code CLI: managed settings ───────────────────────────────────────
echo ""
echo "--- Claude Code CLI managed settings ---"
sudo cp "/Library/Application Support/ClaudeCode/managed-settings.json" \
  "${BACKUP_DIR}/ClaudeCode_managed-settings.json" 2>/dev/null \
  && echo "    ✓ ClaudeCode_managed-settings.json" \
  || echo "    - ClaudeCode managed-settings.json (not found — skipped)"

# ─── Claude Code CLI: user settings ──────────────────────────────────────────
echo ""
echo "--- Claude Code CLI user settings ---"
backup_file "${HOME}/.claude/settings.json"        "claude_settings.json"
backup_file "${HOME}/.claude/remote-settings.json" "claude_remote-settings.json"

# ─── Write manifest ───────────────────────────────────────────────────────────
echo ""
echo "==> Writing manifest..."
{
  echo "backup_timestamp: ${TIMESTAMP}"
  echo "backup_dir: ${BACKUP_DIR}"
  echo "files:"
  ls "${BACKUP_DIR}" | grep -v manifest.txt | sed 's/^/  - /'
} > "${BACKUP_DIR}/manifest.txt"

echo ""
echo "==> Backup complete: ${BACKUP_DIR}"
echo "    Files backed up:"
ls "${BACKUP_DIR}" | grep -v manifest.txt | sed 's/^/      /'
echo ""
echo "    To restore: ./scripts/restore-claude-config.sh ${TIMESTAMP}"
echo "    To list backups: ls ${BACKUP_ROOT}"
