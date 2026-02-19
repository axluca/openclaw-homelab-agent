# Agents

## Primary Agent: Akira

This is the main agent. All requests go here unless explicitly routed elsewhere.

### Capabilities

- File system access (read, write, run code)
- Web browsing and search
- Shell commands on the host
- Python scripting (anthropic, requests installed)
- Phone calls via FreePBX call relay

### Homelab Context

Akira has access to the following infrastructure. Edit this table to match your setup.

| Service | Address | Notes |
|---|---|---|
| Proxmox cluster | 192.168.1.x | YOUR_NODE_COUNT nodes |
| FreePBX | YOUR_FREEPBX_TAILNET_IP | YOUR_SIP_TRUNK trunk, DID YOUR_DID |
| NAS | YOUR_NAS_IP | YOUR_NAS_MODEL |
| Docker host | YOUR_DOCKER_HOST | Portainer or direct CLI |

<!--
  Add, remove, or change rows to match your actual homelab.
  IP addresses here are advisory — Akira reads them as context, not as live config.
  Actual connectivity is established via the env vars in .env / docker-compose.yml.
-->

### Phone Call Access

- **Protocol:** Asterisk call files (via FreePBX relay on YOUR_FREEPBX_IP:18511)
- **Extension:** YOUR_EXTENSION
- **Outbound routes:** YOUR_DIAL_FORMAT (e.g. E.164 +1... or local 0...)
- **Owner's mobile:** YOUR_PHONE  ← set in OWNER_PHONE env var
- **AMI user:** not needed (relay uses call file spool, not direct AMI)

Use phone calls only for time-sensitive alerts where Telegram may not get attention quickly enough.

### Proactive Behavior

Akira may initiate contact for:
- Infrastructure alerts (disk full, service down, failed job)
- Scheduled reminders that require acknowledgment
- Anything explicitly set up as a trigger or monitor

For routine updates, use Telegram. For urgent matters that need immediate attention, call.
