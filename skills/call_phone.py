#!/usr/bin/env python3
"""
call_phone — OpenClaw skill: make a phone call alert
=====================================================
Originates a spoken-word phone call via the FreePBX relay.
The called number hears a TTS message generated from the provided text.

Usage (CLI):
    python3 call_phone.py "<message>"
    python3 call_phone.py "<message>" "+E164_PHONE_NUMBER"

Usage (import):
    from call_phone import call_phone
    result = call_phone("Database backup failed")
    result = call_phone("Disk full on NAS", to="+E164_PHONE_NUMBER")

Environment variables (set in docker-compose.yml or .env):
    FREEPBX_RELAY_URL    — e.g. http://YOUR_FREEPBX_IP:18511
    FREEPBX_RELAY_TOKEN  — shared secret matching the relay's FREEPBX_RELAY_TOKEN
    OWNER_PHONE          — default call destination in E.164 format (e.g. +15551234567)

Returns JSON:
    {"status": "ok",  "to": "+E164...", "sound": "akira-alert-NNN"}   ← success
    {"status": "error", "reason": "..."}                               ← failure
"""

import json
import os
import sys
import urllib.request
import urllib.error

RELAY_URL   = os.environ.get("FREEPBX_RELAY_URL",   "")
RELAY_TOKEN = os.environ.get("FREEPBX_RELAY_TOKEN", "")
OWNER_PHONE = os.environ.get("OWNER_PHONE",          "")


def call_phone(message: str, to: str = OWNER_PHONE) -> dict:
    """
    Place a phone call that speaks `message` to `to` via FreePBX TTS.

    Args:
        message: The text to speak when the call is answered.
        to:      Destination phone number in E.164 format.

    Returns:
        dict with "status": "ok" on success, or "status": "error" on failure.
    """
    if not RELAY_TOKEN:
        return {"status": "error", "reason": "FREEPBX_RELAY_TOKEN not set in environment"}
    if not RELAY_URL:
        return {"status": "error", "reason": "FREEPBX_RELAY_URL not set in environment"}
    if not to:
        return {"status": "error", "reason": "No destination phone number — set OWNER_PHONE or pass 'to'"}

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
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        return {"status": "error", "code": e.code, "reason": f"{e.reason}: {body}"}
    except Exception as e:
        return {"status": "error", "reason": str(e)}


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    message = sys.argv[1]
    to      = sys.argv[2] if len(sys.argv) > 2 else OWNER_PHONE

    result = call_phone(message, to=to)
    print(json.dumps(result, indent=2))
    sys.exit(0 if result.get("status") == "ok" else 1)
