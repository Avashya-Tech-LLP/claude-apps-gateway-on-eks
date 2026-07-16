#!/usr/bin/env bash
# Configure Claude Desktop to route inference through the Claude Apps Gateway.
# Authenticates via your OIDC provider (JumpCloud, Okta, Keycloak, etc.).
#
# Usage:
#   bash setup-claude-desktop.sh          # configure gateway
#   bash setup-claude-desktop.sh restore  # restore previous config
#
# Do NOT run with sudo — the script uses sudo internally where needed.
#
# References:
#   https://docs.anthropic.com/en/docs/claude-code/claude-apps-gateway
#   https://aws.amazon.com/blogs/machine-learning/introducing-claude-apps-gateway-for-aws/

set -euo pipefail

# ─── CONFIGURATION — edit these before running ────────────────────────────────
GATEWAY_URL="https://REPLACE_WITH_YOUR_GATEWAY_HOSTNAME"

# OIDC provider settings (JumpCloud, Okta, Keycloak, Azure AD, etc.)
OIDC_CLIENT_ID="REPLACE_WITH_OIDC_CLIENT_ID"
OIDC_ISSUER="https://REPLACE_WITH_OIDC_ISSUER"
OIDC_AUTH_URL="${OIDC_ISSUER}/oauth2/auth"
OIDC_TOKEN_URL="${OIDC_ISSUER}/oauth2/token"
# ──────────────────────────────────────────────────────────────────────────────

PLIST="/Library/Managed Preferences/com.anthropic.claudefordesktop.plist"
BACKUP_DIR="/Library/Managed Preferences/claude-gateway-backups"
CERT_PATH="$HOME/claude-gateway.pem"

die()     { echo "ERROR: $*" >&2; exit 1; }
require() { command -v "$1" &>/dev/null || die "'$1' not found — install it first."; }

[[ "$EUID" -eq 0 ]] && die "Do not run with sudo. Run as your normal user: bash $0"
require python3

# ─── RESTORE MODE ─────────────────────────────────────────────────────────────
if [[ "${1:-}" == "restore" ]]; then
    echo "==> Available backups:"
    ls -1t "$BACKUP_DIR"/*.plist 2>/dev/null || die "No backups found in $BACKUP_DIR"
    echo ""
    LATEST=$(ls -1t "$BACKUP_DIR"/*.plist | head -1)
    echo "    Latest backup: $LATEST"
    read -rp "Restore this backup? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    sudo cp "$LATEST" "$PLIST"
    echo "    Restored: $PLIST"
    osascript -e 'quit app "Claude"' 2>/dev/null || true
    sleep 2
    open -a Claude
    exit 0
fi

# ─── 1. Backup existing config ────────────────────────────────────────────────
echo "==> Backing up existing config..."
sudo mkdir -p "$BACKUP_DIR"
if [[ -f "$PLIST" ]]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    sudo cp "$PLIST" "$BACKUP_DIR/backup_${TIMESTAMP}.plist"
    echo "    Backed up to: $BACKUP_DIR/backup_${TIMESTAMP}.plist"
else
    echo "    No existing config — skipping backup."
fi

# ─── 2. Trust self-signed gateway certificate ─────────────────────────────────
echo ""
echo "==> Trusting gateway certificate..."
echo "    Fetching current certificate from gateway..."

GATEWAY_HOST="${GATEWAY_URL#https://}"
LIVE_CERT=$(echo Q | openssl s_client \
    -connect "${GATEWAY_HOST}:443" \
    -servername "${GATEWAY_HOST}" \
    -timeout 10 2>/dev/null | openssl x509 2>/dev/null || true)

if [[ -n "$LIVE_CERT" ]]; then
    echo "$LIVE_CERT" > "$CERT_PATH"
    echo "    Using live certificate from gateway."
else
    die "Could not reach gateway at ${GATEWAY_URL}. Check GATEWAY_URL and network access."
fi

echo "    A macOS password prompt will appear to trust the certificate."
osascript -e "do shell script \"security delete-certificate -c 'claude-gateway' /Library/Keychains/System.keychain 2>/dev/null; security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain '${CERT_PATH}'\" with administrator privileges" \
    || die "Certificate trust failed — please enter your Mac password when prompted."
echo "    Certificate trusted in System Keychain."

# ─── 3. Write managed plist with OIDC config ──────────────────────────────────
echo ""
echo "==> Writing Claude Desktop managed preferences..."
sudo mkdir -p "/Library/Managed Preferences"

PLIST_CONTENT=$(python3 - <<PYEOF
import plistlib, json, base64

data = {
    'inferenceProvider':    'gateway',
    'inferenceGatewayBaseUrl': '${GATEWAY_URL}',
    'inferenceGatewayOidc': json.dumps({
        'clientId':            '${OIDC_CLIENT_ID}',
        'issuer':              '${OIDC_ISSUER}/',
        'authorizationUrl':    '${OIDC_AUTH_URL}',
        'tokenUrl':            '${OIDC_TOKEN_URL}',
        'bearerTokenType':     'access_token',
        'scopes':              'openid email profile',
        'appendOfflineAccess': True,
    }),
    'chatTabEnabled': True,
}
print(base64.b64encode(plistlib.dumps(data)).decode())
PYEOF
)
echo "$PLIST_CONTENT" | base64 --decode | sudo tee "${PLIST}" > /dev/null
echo "    Written: ${PLIST}"

# ─── 4. Relaunch Claude Desktop ───────────────────────────────────────────────
echo ""
echo "==> Relaunching Claude Desktop..."
osascript -e 'quit app "Claude"' 2>/dev/null || true
sleep 2
open -a Claude

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Setup complete!"
echo ""
echo "  First launch: browser will open to your OIDC"
echo "  provider. Log in with your corporate credentials."
echo "  After that, token refreshes automatically."
echo ""
echo "  To restore previous config:"
echo "    bash $0 restore"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
