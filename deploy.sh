#!/usr/bin/env bash
# deploy.sh — Deploy OpenClaw AI agent to your homelab VM
# Uses pre-built image: ghcr.io/coollabsio/openclaw:latest
#   Community-maintained image tracking official OpenClaw CalVer releases.
#   Source: https://github.com/coollabsio/openclaw
#   Registry: ghcr.io/coollabsio/openclaw  (updated every ~6h)
#
# Usage:
#   ./deploy.sh               — initial deploy (container + persona files + skills)
#   ./deploy.sh --update      — pull latest image and restart (data persists)
#   ./deploy.sh --setup-host  — (re)install host-level tailnet services (nginx/SSL/systemd)
#   ./deploy.sh --setup-freepbx — (re)install FreePBX call relay on the FreePBX VM
#
# ─── TAILNET DELTA ────────────────────────────────────────────────────────────
#
# These services run on your VM OUTSIDE the container. They are not replaced
# on image updates. Re-apply with --setup-host if the VM is rebuilt.
#
# On YOUR_VM (DEPLOY_VM in .env):
#
#   1. nginx reverse proxy
#        • Listens :443 SSL + :80 redirect
#        • server_name: YOUR_AGENT_DOMAIN (e.g. akira.yourdomain.com)
#        • Auto-injects gateway token via 302 redirect on bare /
#        • Proxies to http://127.0.0.1:18790 (container port 8080 → host 18790)
#        • Full WebSocket support
#
#   2. Self-signed SSL cert  /etc/nginx/ssl/openclaw.crt + .key
#        • CN=YOUR_AGENT_DOMAIN, SAN=DNS:YOUR_AGENT_DOMAIN
#        • 10-year validity — only used inside your private tailnet
#        • Clients must accept the cert (or add to trust store)
#
#   3. Auto-approve service  /etc/systemd/system/openclaw-auto-approve.service
#        • Polls the devices/pending.json volume mount every 2s
#        • Calls: docker exec openclaw openclaw devices approve <rid>
#        • Always enabled; survives reboots
#
#   4. Headscale DNS record (manual step — see README)
#        • Add to extra_records in your Headscale config.yaml:
#          { name: "akira.yourdomain.com", type: "A", value: "YOUR_VM_TAILNET_IP" }
#        • Restart Headscale to propagate
#
# On YOUR_FREEPBX_VM (FREEPBX_VM in .env):
#
#   5. FreePBX call relay  /usr/local/bin/freepbx-ami-relay.py
#        • Listens on 0.0.0.0:18511 (tailtnet-reachable, not public)
#        • Auth: X-Relay-Token header (from FREEPBX_RELAY_TOKEN in .env)
#        • POST /call {"to": "+1...", "message": "alert text"}
#        • flite TTS → sox 8kHz PCM → Asterisk call file in spool
#        • systemd: akira-ami-relay.service (enabled, survives reboots)
#
# ─── CONTAINER DELTA (auto-preserved on every image update) ───────────────────
#
#   configure.js inside the image reads env vars and writes openclaw.json on
#   every container start. docker compose pull && docker compose up -d is safe.
#
#   Key env vars (from .env):
#     ANTHROPIC_API_KEY         — Claude models
#     AKIRA_GATEWAY_TOKEN       — Bearer token for API + UI
#     AKIRA_TELEGRAM_BOT_TOKEN  — Telegram bot
#     AKIRA_TELEGRAM_CHAT_ID    — Allowed Telegram user ID
#     FREEPBX_RELAY_URL         — http://YOUR_FREEPBX_IP:18511
#     FREEPBX_RELAY_TOKEN       — Relay shared secret
#     OWNER_PHONE               — Default call destination (E.164)
#
# ─────────────────────────────────────────────────────────────────────────────
# Requirements: ssh key access to DEPLOY_VM and (optionally) FREEPBX_VM

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env
if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
    echo "ERROR: .env not found. Copy .env.example to .env and fill in your values."
    exit 1
fi
source "$SCRIPT_DIR/.env"

# Required variables
VM="${DEPLOY_VM:?DEPLOY_VM not set in .env}"
DEPLOY_DIR="${DEPLOY_DIR:?DEPLOY_DIR not set in .env}"
DATA_DIR="${DATA_DIR:?DATA_DIR not set in .env}"
DOMAIN="${AGENT_DOMAIN:-openclaw.yourdomain.com}"

UPDATE=false
SETUP_HOST=false
SETUP_FREEPBX=false
for arg in "$@"; do
    [[ "$arg" == "--update" ]]         && UPDATE=true
    [[ "$arg" == "--setup-host" ]]     && SETUP_HOST=true
    [[ "$arg" == "--setup-freepbx" ]]  && SETUP_FREEPBX=true
done

# ── Host-level tailnet delta setup (idempotent) ──────────────────────────────
setup_host() {
    echo "==> Setting up host-level tailnet services on $VM"

    # 1. SSL cert (skipped if already exists)
    echo "--- SSL cert..."
    ssh "$VM" "[ -f /etc/nginx/ssl/openclaw.crt ] && echo '    cert exists, skipping' || \
        sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/openclaw.key -out /etc/nginx/ssl/openclaw.crt \
        -subj '/CN=${DOMAIN}' -addext 'subjectAltName=DNS:${DOMAIN}' 2>/dev/null \
        && echo '    cert created'"

    # 2. nginx vhost
    echo "--- nginx vhost..."
    ssh "$VM" "sudo mkdir -p /etc/nginx/ssl && sudo tee /etc/nginx/sites-available/openclaw > /dev/null" << NGINX
server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate     /etc/nginx/ssl/openclaw.crt;
    ssl_certificate_key /etc/nginx/ssl/openclaw.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location / {
        set \$do_redirect "";
        if (\$uri = /) { set \$do_redirect "Y"; }
        if (\$arg_token != "") { set \$do_redirect ""; }
        if (\$http_upgrade != "") { set \$do_redirect ""; }
        if (\$do_redirect = "Y") {
            return 302 \$scheme://\$host/?token=${AKIRA_GATEWAY_TOKEN};
        }
        proxy_pass http://127.0.0.1:18790;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
NGINX
    ssh "$VM" "sudo ln -sf /etc/nginx/sites-available/openclaw /etc/nginx/sites-enabled/openclaw \
        && sudo nginx -t && sudo systemctl reload nginx && echo '    nginx reloaded'"

    # 3. Auto-approve script + service
    echo "--- auto-approve service..."
    local DATA_DEVICES="${DATA_DIR}/.openclaw/devices"
    # Use named volume path when using named volumes in docker-compose
    # Adjust DATA_DEVICES if you use bind mounts instead
    ssh "$VM" "sudo tee /usr/local/bin/openclaw-auto-approve.sh > /dev/null" << SH
#!/bin/bash
# Adjust PENDING path to match your data volume mount point
PENDING="${DATA_DEVICES}/pending.json"
while true; do
    if [ -f "\$PENDING" ] && [ -s "\$PENDING" ]; then
        RIDS=\$(python3 -c "
import json
try:
    with open('\$PENDING') as f:
        data = json.load(f)
    for rid in data: print(rid)
except: pass
" 2>/dev/null)
        for RID in \$RIDS; do
            [ -n "\$RID" ] && docker exec openclaw openclaw devices approve "\$RID" 2>/dev/null \\
                && echo "\$(date): Auto-approved device \$RID"
        done
    fi
    sleep 2
done
SH
    ssh "$VM" "sudo chmod +x /usr/local/bin/openclaw-auto-approve.sh"
    ssh "$VM" "sudo tee /etc/systemd/system/openclaw-auto-approve.service > /dev/null" << 'UNIT'
[Unit]
Description=Auto-approve OpenClaw device pairing
After=docker.service network.target
Requires=docker.service
[Service]
Type=simple
ExecStart=/usr/local/bin/openclaw-auto-approve.sh
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
    ssh "$VM" "sudo systemctl daemon-reload && sudo systemctl enable --now openclaw-auto-approve.service \
        && echo '    auto-approve running'"

    echo "==> Host setup complete"
    echo "    Remaining manual step: add DNS record to Headscale extra_records:"
    echo "      { name: \"${DOMAIN}\", type: \"A\", value: \"YOUR_VM_TAILNET_IP\" }"
}

# ── FreePBX relay setup (idempotent) ─────────────────────────────────────────
setup_freepbx_relay() {
    local FREEPBX_VM="${FREEPBX_VM:?FREEPBX_VM not set in .env}"
    echo "==> Setting up FreePBX call relay on $FREEPBX_VM"

    echo "--- Copying relay script..."
    scp "$SCRIPT_DIR/infra/freepbx-ami-relay.py" "$FREEPBX_VM:/tmp/freepbx-ami-relay.py"
    ssh "$FREEPBX_VM" "sudo mv /tmp/freepbx-ami-relay.py /usr/local/bin/freepbx-ami-relay.py \
        && sudo chmod 755 /usr/local/bin/freepbx-ami-relay.py \
        && echo '    relay script installed'"

    echo "--- Writing relay env file..."
    ssh "$FREEPBX_VM" "sudo tee /etc/freepbx-relay.env > /dev/null" << RELAYENV
FREEPBX_RELAY_TOKEN=${FREEPBX_RELAY_TOKEN}
RELAY_PORT=18511
RELAYENV
    ssh "$FREEPBX_VM" "sudo chmod 600 /etc/freepbx-relay.env"

    echo "--- Installing systemd service..."
    ssh "$FREEPBX_VM" "sudo tee /etc/systemd/system/openclaw-ami-relay.service > /dev/null" << 'UNIT'
[Unit]
Description=OpenClaw Phone Call Relay (FreePBX)
After=network.target asterisk.service
[Service]
Type=simple
EnvironmentFile=/etc/freepbx-relay.env
ExecStart=/usr/bin/python3 /usr/local/bin/freepbx-ami-relay.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
    ssh "$FREEPBX_VM" "sudo systemctl daemon-reload \
        && sudo systemctl enable --now openclaw-ami-relay.service \
        && echo '    openclaw-ami-relay running'"

    echo "==> FreePBX relay ready on http://YOUR_FREEPBX_IP:18511"
}

[[ "$SETUP_HOST" == true ]]     && { setup_host;          exit 0; }
[[ "$SETUP_FREEPBX" == true ]]  && { setup_freepbx_relay; exit 0; }

# ── Main deploy ───────────────────────────────────────────────────────────────
echo "==> Deploying OpenClaw to $VM"

echo "--- Creating directories..."
ssh "$VM" "mkdir -p $DEPLOY_DIR $DATA_DIR/workspace"

echo "--- Syncing docker-compose.yml..."
scp "$SCRIPT_DIR/docker-compose.yml" "$VM:$DEPLOY_DIR/docker-compose.yml"

echo "--- Writing .env on VM..."
ssh "$VM" "cat > $DEPLOY_DIR/.env" << ENVFILE
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
AKIRA_GATEWAY_TOKEN=${AKIRA_GATEWAY_TOKEN}
AKIRA_TELEGRAM_BOT_TOKEN=${AKIRA_TELEGRAM_BOT_TOKEN}
AKIRA_TELEGRAM_CHAT_ID=${AKIRA_TELEGRAM_CHAT_ID}
FREEPBX_RELAY_URL=${FREEPBX_RELAY_URL}
FREEPBX_RELAY_TOKEN=${FREEPBX_RELAY_TOKEN}
OWNER_PHONE=${OWNER_PHONE}
ENVFILE

echo "--- Syncing persona files..."
for f in SOUL.md IDENTITY.md AGENTS.md; do
    if [[ -f "$SCRIPT_DIR/persona/$f" ]]; then
        scp "$SCRIPT_DIR/persona/$f" "$VM:$DATA_DIR/workspace/$f"
        echo "    Synced persona/$f"
    fi
done

echo "--- Syncing skills..."
if [[ -d "$SCRIPT_DIR/skills" ]]; then
    ssh "$VM" "mkdir -p $DATA_DIR/workspace/skills"
    for skill in "$SCRIPT_DIR/skills/"*.py; do
        [[ -f "$skill" ]] || continue
        scp "$skill" "$VM:$DATA_DIR/workspace/skills/$(basename "$skill")"
        echo "    Synced skills/$(basename "$skill")"
    done
fi

if [[ "$UPDATE" == true ]]; then
    echo "--- Pulling latest image..."
    ssh "$VM" "cd $DEPLOY_DIR && docker compose pull && docker compose up -d"
    echo "--- Verifying host-level services..."
    ssh "$VM" "[ -f /etc/nginx/sites-enabled/openclaw ] \
        && echo '    nginx: OK' || echo '    WARN: nginx missing — run ./deploy.sh --setup-host'"
    ssh "$VM" "systemctl is-active openclaw-auto-approve.service >/dev/null 2>&1 \
        && echo '    auto-approve: OK' || echo '    WARN: auto-approve not running — run ./deploy.sh --setup-host'"
    if [[ -n "${FREEPBX_VM:-}" ]]; then
        ssh "${FREEPBX_VM}" "systemctl is-active openclaw-ami-relay.service >/dev/null 2>&1 \
            && echo '    ami-relay: OK' || echo '    WARN: ami-relay not running — run ./deploy.sh --setup-freepbx'" 2>/dev/null \
            || echo '    WARN: cannot reach FREEPBX_VM'
    fi
else
    echo "--- Starting container..."
    ssh "$VM" "cd $DEPLOY_DIR && docker compose up -d"
fi

echo ""
echo "==> Done. OpenClaw is running on $VM:18790"
echo "    Logs:   ssh $VM 'docker logs -f openclaw'"
echo "    Status: ssh $VM 'cd $DEPLOY_DIR && docker compose ps'"
