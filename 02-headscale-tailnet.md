# Self-Hosted VPN with Headscale: One Mesh Network for Your Entire Homelab

*How to run your own Tailscale-compatible coordination server on a $5 VPS — so every device, VM, and container you own lives on a single private network, accessible from anywhere.*

---

The problem with homelabs is that they're local. You can run 20 services on 4 Proxmox nodes, but the moment you leave the house, everything disappears behind your router's NAT. You either expose ports to the internet (bad idea for internal services), use a self-hosted VPN (painful to manage), or pay for a commercial tunnel service.

I went down a different path. I run [Headscale](https://github.com/juanfont/headscale) — the open-source, self-hosted implementation of the Tailscale control plane — on a small cloud VPS. Every device I own connects to it: Proxmox nodes, Synology NAS, Mac laptops, VMs, LXC containers. They all get a stable `100.64.x.x` IP. They can reach each other from anywhere, without opening a single firewall port.

This article walks through the full setup: Headscale on a VPS with Traefik for HTTPS, Tailscale clients on all homelab devices, MagicDNS with custom records, and a custom domain to wrap it all together.

## Why Headscale Instead of Running a WireGuard Server?

Standard WireGuard requires you to manually manage peer configs — add a device, edit every other peer's config, restart the daemon. It's fine for two or three devices. It doesn't scale.

Tailscale solves the peer management problem with a coordination server that handles key exchange, NAT traversal, and device discovery. The catch: it's a commercial service with free tier limits and phone-home behavior.

Headscale implements the same protocol — fully compatible with the standard Tailscale client — but you run the control plane yourself. You're not limited to 3 users or 100 devices. No telemetry. No dependency on Tailscale's infrastructure.

The VPN traffic itself still flows peer-to-peer via WireGuard. The VPS only handles signaling. So a $5/month VPS with 1 vCPU and 1 GB RAM is more than enough.

## VPS Setup

I use Hostinger's KVM2 plan (~$5/month, shared) running Ubuntu 24.04 LTS. Any VPS with a public IP works. Requirements:

- Docker CE installed
- Port 80 and 443 open
- Port 41641/UDP open (Tailscale DERP/WireGuard fallback — optional but useful)

The full stack on the VPS runs in Docker Compose:

- **Traefik** — reverse proxy with Let's Encrypt for all HTTPS
- **Headscale** — the control plane
- **Headscale Admin** — web GUI (protected by Basic Auth)
- **Other services** — I also run n8n and Vaultwarden on the same host

## Deploying Headscale with Traefik

`docker-compose.yml` (relevant excerpt):

```yaml
services:
  traefik:
    image: traefik:3.6
    command:
      - --providers.docker=true
      - --providers.docker.exposedByDefault=false
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.le.acme.httpchallenge=true
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
      - --certificatesresolvers.le.acme.email=you@yourdomain.com
      - --certificatesresolvers.le.acme.storage=/letsencrypt/acme.json
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - letsencrypt:/letsencrypt

  headscale:
    image: headscale/headscale:0.28
    volumes:
      - ./headscale/config:/etc/headscale
      - ./headscale/data:/var/lib/headscale
    command: serve
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.headscale.rule=Host(`headscale.yourdomain.com`)"
      - "traefik.http.routers.headscale.tls.certresolver=le"
      - "traefik.http.services.headscale.loadbalancer.server.port=8080"
      # WebSocket support for Tailscale noise protocol
      - "traefik.http.middlewares.headscale-cors.headers.accesscontrolalloworiginlist=https://headscale.yourdomain.com"

  headscale-admin:
    image: goodieshq/headscale-admin:latest
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.hs-admin.rule=Host(`headscale.yourdomain.com`) && PathPrefix(`/admin`)"
      - "traefik.http.routers.hs-admin.tls.certresolver=le"
      - "traefik.http.routers.hs-admin.middlewares=hs-auth"
      - "traefik.http.middlewares.hs-auth.basicauth.users=youruser:$$apr1$$..."
```

For Headscale's `config.yaml`, the critical settings:

```yaml
server_url: https://headscale.yourdomain.com

listen_addr: 0.0.0.0:8080
metrics_listen_addr: 0.0.0.0:9090
grpc_listen_addr: 0.0.0.0:50443

base_domain: ts.yourdomain.com   # NOT the same domain as server_url

dns:
  magic_dns: true
  override_local_dns: true
  base_domain: ts.yourdomain.com
  nameservers:
    global:
      - 1.1.1.1

# Custom DNS records for private services — visible only inside the tailnet
extra_records:
  - name: "proxmox.yourdomain.com"
    type: A
    value: "100.64.0.2"
  - name: "nas.yourdomain.com"
    type: A
    value: "100.64.0.3"
  - name: "akira.yourdomain.com"
    type: A
    value: "100.64.0.9"
```

Important: `base_domain` cannot be the parent domain of `server_url`. If your server is at `headscale.yourdomain.com`, use `ts.yourdomain.com` or `vpn.yourdomain.com` as the base domain. Headscale rejects configurations where `server_url` is a subdomain of `base_domain`.

Deploy:

```bash
docker compose up -d
curl https://headscale.yourdomain.com/health
# → {"status":"ok"}
```

## Creating a User and Pre-Auth Keys

Everything in Headscale is under a "user" (think: namespace). All my devices live under one user:

```bash
docker exec headscale headscale users create yourname
docker exec headscale headscale preauthkeys create --user yourname --reusable --expiration 90d
# → Save this key
```

The reusable pre-auth key means you can register new devices without running the approve command for each one. Convenient for adding VMs.

## Connecting Devices

### Linux Nodes (Proxmox, Ubuntu VMs, Debian VMs)

```bash
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled
tailscale up --login-server https://headscale.yourdomain.com --authkey <your-preauthkey>

# Confirm registration
docker exec headscale headscale nodes list
```

### Synology NAS

Synology's built-in Tailscale package connects to official Tailscale only. You need a manually installed SPK from [pkgs.tailscale.com](https://pkgs.tailscale.com). Check your NAS architecture first:

```bash
# On the NAS via SSH:
uname -m   # armv7l, x86_64, etc.
```

Download the correct SPK for your Tailscale version, install via DSM Package Manager → Manual Install, then:

```bash
# SSH into NAS
tailscale up --login-server https://headscale.yourdomain.com --authkey <preauthkey>
```

**Note:** If your NAS reports HTTP 308 redirect errors, you're running a Tailscale version too old to handle Headscale's redirect behavior. Upgrade to at least v1.90+.

### Unprivileged LXC Containers (Portainer, etc.)

LXC containers without a TUN device need userspace networking mode:

```bash
# Install Tailscale inside the container (standard install script works)
# Then configure userspace mode:
mkdir -p /etc/systemd/system/tailscaled.service.d
cat > /etc/systemd/system/tailscaled.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/tailscaled --tun=userspace-networking --socket=/run/tailscale/tailscaled.sock
EOF
systemctl daemon-reload
systemctl restart tailscaled
tailscale up --login-server https://headscale.yourdomain.com --authkey <preauthkey>
```

Connectivity works normally. The performance penalty of userspace mode is negligible for control traffic.

### macOS

Download [Tailscale standalone](https://pkgs.tailscale.com/stable/#macos) (not the App Store version — the CLI is required):

```bash
/Applications/Tailscale.app/Contents/MacOS/Tailscale login \
  --login-server https://headscale.yourdomain.com
```

A browser window opens. Copy the registration command that appears, run it in your Headscale container. Done.

## MagicDNS and the `extra_records` Pattern

Once all nodes are connected, Headscale's MagicDNS resolves `nodename.ts.yourdomain.com` to each device's tailnet IP. That's nice for direct node access. For services, though, you want human-readable names without the `.ts` prefix.

The `extra_records` block in `config.yaml` lets you publish arbitrary A records to all tailnet clients:

```yaml
extra_records:
  - name: "your_agent_name.yourdomain.com"
    type: A
    value: "100.64.0.10"
```

After editing, restart Headscale (`docker compose restart headscale`) and the record resolves on every tailnet device:

```
$ nslookup your_agent_name.yourdomain.com
Server: 100.100.100.100
Non-authoritative answer:
Name: your_agent_name.yourdomain.com
Address: 100.64.0.10
```

This is how I make services accessible by domain name from any device on the mesh — without DNS servers, without split-horizon DNS, without touching my router. The `100.100.100.100` resolver is the Tailscale MagicDNS daemon running on each client.

**Important:** `extra_records` names must be subdomains of a domain you control in public DNS. Otherwise, some clients will try the public resolver and fail. Using `yourdomain.com` works because Headscale's MagicDNS answers before the query reaches public DNS.

## The Final Network Topology

After all devices are enrolled, my tailnet looks like this:

| Device | Role | Tailnet IP |
|--------|------|-----------|
| Mac Mini | Primary workstation | 100.64.0.1 |
| Proxmox pve-201 | Hypervisor host | 100.64.0.2 |
| Synology NAS | Backup storage | 100.64.0.3 |
| MacPro | Dev machine | 100.64.0.4 |
| Portainer LXC | Docker management | 100.64.0.5 |
| pve-198 | Proxmox node | 100.64.0.6 |
| pve-199 | Proxmox node | 100.64.0.7 |
| pve-200 | Proxmox node | 100.64.0.8 |
| AI agent VM | OpenClaw / Akira | 100.64.0.9 |
| FreePBX VM | Phone / Asterisk | 100.64.0.10 |

From my phone with Tailscale installed, I can reach every single one of these. From a hotel WiFi. From a coffee shop. No VPN toggles, no port forwarding. It just works.

## What This Enables

The real value isn't remote access to Proxmox (though that's great). It's that every service you build can talk to every other service by a stable internal IP or domain name. The AI agent on `100.64.0.9` can call the FreePBX API on `100.64.0.10` — both inside the tailnet, neither exposed to the internet. The Synology NAS can receive backups from all Proxmox nodes using a consistent NFS mount path that never changes when IPs shift.

The tailnet becomes the backbone for everything else you build on top.

---

*In the next article, I'll show how I deployed OpenClaw, a self-hosted AI agent, as a Docker container on one of these VMs — with nginx token injection for secure access, a Telegram bot, and a FreePBX call relay that lets the agent phone me for urgent alerts.*

*GitHub: [axluca/openclaw-homelab-agent](https://github.com/axluca/openclaw-homelab-agent)*

---

**Tags:** self-hosted, vpn, headscale, tailscale, wireguard, homelab, docker, networking

---

## Header Image Prompt

> A dark, sleek network topology visualization floating in 3D space: glowing nodes (laptop, server rack, NAS, phone) connected by pulsing neon-blue WireGuard tunnels, all converging on a central cloud server. Deep space background with subtle circuit board texture. Style: futuristic digital art, cyan and midnight blue palette, cinematic lighting, 16:9.
