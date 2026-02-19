# Akira — OpenClaw AI Agent on Your Homelab

A reproducible setup for running a self-hosted OpenClaw AI agent on a Proxmox homelab,
accessible via a Headscale private tailnet, with Telegram and phone call capabilities.

## What this is

This repository contains the configuration and deployment scripts to run
[OpenClaw](https://github.com/coollabsio/openclaw) as a Docker container with:

- **Private HTTPS access** via a Headscale tailnet at a custom domain (e.g. `akira.yourdomain.com`)
- **Telegram bot** integration for chat-based interaction
- **Phone call alerts** via a FreePBX/Asterisk relay using flite TTS
- **Auto-approve** device pairing so the UI is accessible without manual steps
- **Automatic image updates** — `./deploy.sh --update` is always safe

## Repository structure

```
.
├── docker-compose.yml          # Container definition — all config via env vars
├── deploy.sh                   # Deploy + update + host setup script
├── .env.example                # Template — copy to .env and fill in your values
├── infra/
│   └── freepbx-ami-relay.py   # HTTP relay: Akira → Asterisk call files
├── skills/
│   └── call_phone.py          # OpenClaw skill: place a TTS phone call
└── persona/
    ├── SOUL.md                 # Agent personality definition
    ├── IDENTITY.md             # Agent identity, owner, infrastructure context
    └── AGENTS.md               # Capabilities, routing, homelab context
```

## Prerequisites

- A Proxmox homelab with at least one Ubuntu 24.04 VM (2 vCPU / 2 GB RAM minimum)
- Docker 24+ and Docker Compose v2+ on that VM
- A [Headscale](https://headscale.net) server (or Tailscale) for VPN access
- A Telegram bot token from [@BotFather](https://t.me/BotFather) (optional)
- A FreePBX/Asterisk server with an outbound SIP trunk (optional, for phone calls)
- An [Anthropic API key](https://console.anthropic.com) (or any supported provider)

## Quick start

### 1. Clone and configure

```bash
git clone https://github.com/YOUR_USERNAME/akira-openclaw.git
cd akira-openclaw
cp .env.example .env
# Edit .env with your actual values
```

### 2. Deploy to your VM

```bash
# Initial deploy
./deploy.sh

# Set up host-level services (nginx, SSL, auto-approve) — run once
./deploy.sh --setup-host

# Set up FreePBX relay — run once on the FreePBX VM
./deploy.sh --setup-freepbx
```

### 3. Access

Open `https://akira.yourdomain.com` from any device on your tailnet.
The gateway token is auto-injected — no manual login required.

## Updating OpenClaw

The image (`ghcr.io/coollabsio/openclaw`) is rebuilt automatically from the
[official OpenClaw releases](https://github.com/coollabsio/openclaw) every ~6 hours.
To update:

```bash
./deploy.sh --update
```

This pulls the latest image, restarts the container, and verifies all host-level
services (nginx, SSL cert, auto-approve, FreePBX relay) are still intact.

## Architecture

```
[Any tailnet device]
        │ HTTPS
        ▼
[nginx on VM :443]  ←── self-signed cert (tailnet only)
   302 token inject
        │ HTTP
        ▼
[OpenClaw container :18790]
   ghcr.io/coollabsio/openclaw:latest
   volume: /data  (state + workspace)
        │
        ├── Telegram @YourBot  (env: TELEGRAM_BOT_TOKEN)
        │
        └── skills/call_phone.py
                │ POST /call
                ▼
        [FreePBX relay :18511]  ←── X-Relay-Token auth
           flite TTS → sox → call file
                │
                ▼
        [Asterisk → SIP trunk → PSTN]
```

## Security notes

- The agent listens only on the private tailnet. No ports are exposed publicly.
- The nginx `AUTH_PASSWORD` env var can be set for an additional HTTP basic auth layer.
- The FreePBX relay accepts connections only from your tailnet (firewall accordingly).
- All secrets live in `.env` which is gitignored. Never commit `.env`.

## Related articles

- [Part 1: Building a Proxmox homelab cluster with mini PCs](#)
- [Part 2: Private networking with Headscale on a cloud VPS](#)
- [Part 3: Self-hosted AI agent on your tailnet with OpenClaw](#)

*(Links will be updated once articles are published on Medium)*

## License

MIT
