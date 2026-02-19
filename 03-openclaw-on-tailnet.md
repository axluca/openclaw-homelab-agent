# Running a Self-Hosted AI Agent That Can Call You on the Phone

*How I deployed OpenClaw on my homelab tailnet — with nginx token injection, Telegram integration, and a FreePBX relay that lets the agent call my mobile when something needs attention.*

---

I've tried the hosted AI assistant route. The privacy tradeoffs bothered me more as the use cases got more personal — checking my homelab state, reading logs, interacting with internal services that have no business leaving my network.

So I went all-in on self-hosted. The result is a persistent AI agent called Akira that lives on a VM in my Proxmox cluster. It can browse the web, run code, manage files, respond on Telegram, and — the part that still impresses me a little — call my phone when something is actually urgent.

This article covers the full deployment: the Docker image, nginx access layer, token injection trick, Telegram bot, and the FreePBX call relay architecture.

## The OpenClaw Image

[OpenClaw](https://openclaw.dev) is a self-hosted AI agent platform. There's a community-maintained Docker image that tracks official releases and updates roughly every six hours:

```
ghcr.io/coollabsio/openclaw:latest
```

You don't need to build anything. The image is fully driven by environment variables — it runs `configure.js` on startup to write its own `openclaw.json` from your env vars. That means `docker compose pull && docker compose up -d` safely updates the agent without touching your data.

## The VM

I run OpenClaw on a dedicated Ubuntu 24.04 LTS VM on Proxmox:

- **4 GB RAM** (Claude API is the brain; the container itself is lightweight)
- **32 GB disk** (mostly workspace and logs)
- **Tailscale installed** → IP `100.64.0.9` on my Headscale tailnet
- **Port 18790** exposed on localhost (Docker host) — nginx terminates TLS externally

This isn't a GPU VM. The "thinking" happens in Claude's API. The agent needs CPU and RAM for browser automation and Python execution, not inference.

## Docker Compose

```yaml
services:
  openclaw:
    image: ghcr.io/coollabsio/openclaw:latest
    container_name: openclaw
    restart: unless-stopped
    ports:
      - "127.0.0.1:18790:8080"   # Only localhost — nginx terminates TLS
    volumes:
      - openclaw-data:/app/.openclaw
      - browser-data:/app/.browser
    environment:
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
      - OPENCLAW_GATEWAY_TOKEN=${AKIRA_GATEWAY_TOKEN}
      - TELEGRAM_BOT_TOKEN=${AKIRA_TELEGRAM_BOT_TOKEN}
      - TELEGRAM_CHAT_ID=${AKIRA_TELEGRAM_CHAT_ID}
      - FREEPBX_RELAY_URL=${FREEPBX_RELAY_URL}
      - FREEPBX_RELAY_TOKEN=${FREEPBX_RELAY_TOKEN}
      - OWNER_PHONE=${OWNER_PHONE}
      - TZ=UTC

volumes:
  openclaw-data:
  browser-data:
```

Two named volumes handle persistence: `openclaw-data` for agent config, memory, and conversation history; `browser-data` for the headless browser cache. Image updates don't touch volumes, so your persona files and session data survive every `docker compose pull`.

The port binding `127.0.0.1:18790:8080` is intentional. The container only listens on localhost — nginx on the VM handles TLS and then proxies through.

## The HTTPS Access Layer: nginx Token Injection

OpenClaw's API requires a bearer token (`OPENCLAW_GATEWAY_TOKEN`) on every request. The web UI appends it as a `?token=...` query parameter. Asking anyone — including yourself — to manually type a long token every time is friction you don't want.

The nginx configuration injects the token automatically via a 302 redirect on bare root requests:

```nginx
server {
    listen 443 ssl;
    server_name akira.yourdomain.com;

    ssl_certificate     /etc/nginx/ssl/openclaw.crt;
    ssl_certificate_key /etc/nginx/ssl/openclaw.key;

    location / {
        # Inject gateway token on bare / — skip if token already present or WebSocket
        set $do_redirect "";
        if ($uri = /) { set $do_redirect "Y"; }
        if ($arg_token != "") { set $do_redirect ""; }
        if ($http_upgrade != "") { set $do_redirect ""; }

        if ($do_redirect = "Y") {
            return 302 $scheme://$host/?token=YOUR_TOKEN;
        }

        proxy_pass http://127.0.0.1:18790;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
server {
    listen 80;
    server_name akira.yourdomain.com;
    return 301 https://$host$request_uri;
}
```

Since this is a tailnet-only service, I use a self-signed certificate (10-year validity, SAN included). Real Let's Encrypt certs won't issue for `.ts.yourdomain.com` subdomains or private IPs anyway — and the tailnet is my trust boundary.

Generate the cert:

```bash
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/openclaw.key \
  -out /etc/nginx/ssl/openclaw.crt \
  -subj "/CN=akira.yourdomain.com" \
  -addext "subjectAltName=DNS:akira.yourdomain.com"
```

Add the cert to your Headscale DNS record:

```yaml
# In headscale config.yaml extra_records:
- name: "akira.yourdomain.com"
  type: A
  value: "100.64.0.9"
```

Restart Headscale, and `https://akira.yourdomain.com` works from every tailnet device. Visiting the root URL redirects to `?token=...` automatically. You can bookmark it. No manual token entry.

## Device Pairing Auto-Approval

OpenClaw generates a device pairing request the first time you access it from a new client. You have to approve it in the API. For a homelab where you're the only user, doing this manually every time is needless friction.

The fix is a small systemd service that watches the pending devices file and calls the approval API automatically:

```bash
# /usr/local/bin/openclaw-auto-approve.sh
#!/bin/bash
PENDING="${DATA_DIR}/.openclaw/devices/pending.json"
while true; do
    if [ -f "$PENDING" ] && [ -s "$PENDING" ]; then
        RIDS=$(python3 -c "
import json
try:
    with open('$PENDING') as f:
        data = json.load(f)
    for rid in data: print(rid)
except: pass
" 2>/dev/null)
        for RID in $RIDS; do
            [ -n "$RID" ] && docker exec openclaw openclaw devices approve "$RID"
        done
    fi
    sleep 2
done
```

Enable it as a systemd service and you'll never see a device approval prompt again.

## Telegram Integration

The Telegram bot is the easiest piece. Create a bot via [@BotFather](https://t.me/BotFather) on Telegram, copy the token, and set `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` in your `.env`.

`TELEGRAM_CHAT_ID` locks the bot to your account only — it rejects messages from anyone else. Get your chat ID by sending a message to `@userinfobot` on Telegram.

Once running, you can message the agent from anywhere you have Telegram. It can:

- Answer questions
- Run code and return output
- Browse URLs and summarize pages
- Execute shell commands on the container host (via the code execution tool)
- Initiate calls via FreePBX

## The Phone Call Architecture

This is the part people ask about most, so let me break down how it works.

### The Problem

Docker containers can't dial phones directly. You need something that can talk to an Asterisk-based PBX and trigger an outbound PSTN call. I have a FreePBX 17 VM in the same cluster (`100.64.0.10` on the tailnet), connected to a SIP trunk.

The challenge: exposing Asterisk's AMI (Manager Interface) to the Docker container is a security risk — AMI has no TLS, and a compromised container could interact with the PBX directly. I wanted a narrow, authenticated HTTP API in between.

### The Relay

`freepbx-ami-relay.py` is a small Python HTTP server that runs on the FreePBX VM. It listens on port 18511 and accepts one endpoint:

```
POST /call
Headers: X-Relay-Token: your-shared-secret
Body:    {"to": "+15551234567", "message": "Database backup failed on node 3"}
```

When it receives a valid request, it:

1. Runs `flite` to generate TTS audio from the message
2. Converts it with `sox` to 8kHz mono signed PCM (the format Asterisk expects)
3. Writes a `.call` file to `/var/spool/asterisk/outgoing/`
4. Asterisk picks it up within 1–2 seconds, dials the number, plays the audio

The `.call` file approach is the safest way to trigger Asterisk calls without AMI — no manager interface involvement, Asterisk's own scheduler handles retry logic, and the call file is just a plain text file:

```
Channel: PJSIP/+15551234567@YOUR_TRUNK
Application: Playback
Data: custom/akira-alert-1716800000000
MaxRetries: 2
RetryTime: 30
WaitTime: 45
CallerID: Akira <+YOUR_DID>
```

### The Skill

Inside the OpenClaw container, `call_phone.py` is a simple wrapper:

```python
def call_phone(message: str, to: str = OWNER_PHONE) -> dict:
    payload = json.dumps({"to": to, "message": message}).encode()
    req = urllib.request.Request(
        f"{RELAY_URL}/call",
        data=payload,
        headers={
            "Content-Type": "application/json",
            "X-Relay-Token": RELAY_TOKEN,
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())
```

The agent can call this directly when instructed — "Akira, call me if the backup job fails tonight" — or it can decide proactively based on rules you configure in its persona files.

### End-to-End Flow

```
Agent decides to call
        ↓
call_phone.py (inside container)
        ↓  HTTP POST + X-Relay-Token
freepbx-ami-relay.py (FreePBX VM, localhost)
        ↓  flite TTS → sox conversion
Asterisk call spool (/var/spool/asterisk/outgoing/)
        ↓  <2 seconds
Asterisk dials PSTN via SIP trunk
        ↓
Your phone rings
        ↓
You hear: "Database backup failed on node 3"
```

From agent decision to ringing phone: under 5 seconds on a local cluster.

## Persona Files

OpenClaw loads Markdown files from the workspace to establish the agent's character, knowledge, and behavioral rules. Three files compose the full persona:

- **`SOUL.md`** — tone, values, communication style. Sets the "feel" of the agent.
- **`IDENTITY.md`** — who the agent is, what it can do, how to reach it, what infrastructure it has access to.
- **`AGENTS.md`** — technical table of the homelab: services, IPs, phone extensions, behavioral rules for proactive notifications.

These files live in the agent's workspace volume (persisted across updates). You can edit them at runtime — the agent rereads them on new conversation starts.

The most important line in `AGENTS.md`:

> For routine updates, use Telegram. For urgent matters that need immediate attention, call.

Setting clear behavioral norms in the persona file prevents the agent from calling you at 2am about a `apt update` notification.

## What This Stack Actually Costs

- **VPS for Headscale:** ~$5/month (only handles VPN signaling)
- **Homelab power:** ~35W for the Proxmox cluster
- **Anthropic API:** Claude Haiku is cheap for most interactions; Sonnet is what I use for complex tasks. My personal usage runs ~$3–8/month.
- **SIP trunk for calls:** ~€0.005/minute outbound in Europe. A 30-second alert call is a fraction of a cent.
- **Everything else:** zero operating cost (self-hosted)

## The Actual Experience

What surprised me most isn't that it works — it's how *normal* it feels after a week. I send a Telegram message like "check if pve-200 is under heavy load" and get a real answer 10 seconds later. I said "watch the NAS disk space and call me if it drops below 500 GB" and it did exactly that, once, at 11pm when a backup job ran unexpectedly long.

There's no magic here. It's a container running Claude via the Anthropic API, with SSH access to my cluster and a call relay on my PBX. The architecture took about four hours to build and an afternoon to tune. The persona files took longer — getting the tone right so it doesn't over-explain or flood you with updates takes iteration.

The code for everything in this article — `deploy.sh`, `docker-compose.yml`, the relay script, the call skill, and the template persona files — is in the [GitHub repository](https://github.com/axluca/openclaw-homelab-agent).

---

*Previous articles in this series: [Building a Mini PC Proxmox Cluster](#) | [Self-Hosted VPN with Headscale](#)*

*GitHub: [axluca/openclaw-homelab-agent](https://github.com/axluca/openclaw-homelab-agent)*

---

**Tags:** ai, self-hosted, homelab, docker, openclaw, freepbx, asterisk, llm, claude, infrastructure
