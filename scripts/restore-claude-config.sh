#!/usr/bin/env bash
# Restore Claude config files from a backup created by backup-claude-config.sh.
# Usage: ./restore-claude-config.sh [TIMESTAMP]
# If TIMESTAMP is omitted, restores from the most recent backup.
set -euo pipefail

BACKUP_ROOT="${CLAUDE_GATEWAY_REPO:-$HOME/claude-apps-gateway-on-eks}/backups/claude-config"

# ─── Resolve backup directory ─────────────────────────────────────────────────
if [ "${1:-}" != "" ]; then
  BACKUP_DIR="${BACKUP_ROOT}/$1"
else
  BACKUP_DIR=$(ls -1d "${BACKUP_ROOT}"/[0-9]* 2>/dev/null | sort | tail -1)
fi

[ -d "$BACKUP_DIR" ] || { echo "ERROR: Backup directory not found: ${BACKUP_DIR}"; echo "Available backups:"; ls "${BACKUP_ROOT}" 2>/dev/null || echo "(none)"; exit 1; }

echo "==> Restoring from: ${BACKUP_DIR}"
cat "${BACKUP_DIR}/manifest.txt" 2>/dev/null && echo ""

# ─── Confirm ──────────────────────────────────────────────────────────────────
echo "WARNING: This will overwrite current Claude config files."
echo "Quit Claude Desktop and Claude Code CLI before continuing."
read -p "Continue? [y/N] " -n 1 -r
echo ""
[[ "$REPLY" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

restore_file() {
  local src="${BACKUP_DIR}/$1"
  local dest="$2"
  local use_sudo="${3:-false}"
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "$dest")"
    if [ "$use_sudo" = "true" ]; then
      sudo cp "$src" "$dest"
    else
      cp "$src" "$dest"
    fi
    echo "    ✓ $dest"
  else
    echo "    - $1 (not in backup — skipped)"
  fi
}

# ─── Claude Desktop: managed plist ───────────────────────────────────────────
echo ""
echo "--- Restoring Claude Desktop managed preferences ---"
restore_file \
  "managed_com.anthropic.claudefordesktop.plist" \
  "/Library/Managed Preferences/com.anthropic.claudefordesktop.plist" \
  "true"

# ─── Claude Desktop: user preferences plist ──────────────────────────────────
echo ""
echo "--- Restoring Claude Desktop user preferences ---"
restore_file \
  "user_com.anthropic.claudefordesktop.plist" \
  "${HOME}/Library/Preferences/com.anthropic.claudefordesktop.plist"

# ─── Claude Desktop: app config (standard) ───────────────────────────────────
echo ""
echo "--- Restoring Claude Desktop app config (standard) ---"
restore_file \
  "Claude_claude_desktop_config.json" \
  "${HOME}/Library/Application Support/Claude/claude_desktop_config.json"
restore_file \
  "Claude_config.json" \
  "${HOME}/Library/Application Support/Claude/config.json"

# ─── Claude Desktop: app config (3p/gateway) ─────────────────────────────────
echo ""
echo "--- Restoring Claude Desktop app config (3p/gateway mode) ---"
restore_file \
  "Claude-3p_claude_desktop_config.json" \
  "${HOME}/Library/Application Support/Claude-3p/claude_desktop_config.json"
restore_file \
  "Claude-3p_config.json" \
  "${HOME}/Library/Application Support/Claude-3p/config.json"
restore_file \
  "Claude-3p_developer_settings.json" \
  "${HOME}/Library/Application Support/Claude-3p/developer_settings.json"

# ─── Claude Code CLI: managed settings ───────────────────────────────────────
echo ""
echo "--- Restoring Claude Code CLI managed settings ---"
restore_file \
  "ClaudeCode_managed-settings.json" \
  "/Library/Application Support/ClaudeCode/managed-settings.json" \
  "true"

# ─── Claude Code CLI: user settings ──────────────────────────────────────────
echo ""
echo "--- Restoring Claude Code CLI user settings ---"
restore_file "claude_settings.json"        "${HOME}/.claude/settings.json"
restore_file "claude_remote-settings.json" "${HOME}/.claude/remote-settings.json"

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "==> Restore complete."
echo ""
echo "  Next steps:"
echo "  1. Relaunch Claude Desktop"
echo "  2. Re-run 'claude /login' if Claude Code CLI session was lost"
