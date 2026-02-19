#!/usr/bin/env python3
"""
OpenClaw Phone Call Relay — runs on your FreePBX VM
====================================================
Accepts HTTP POST requests from the OpenClaw Docker container and originates
Asterisk calls using Asterisk call files. No AMI network exposure required —
the relay runs locally and writes spool files that Asterisk picks up directly.

Endpoints:
  POST /call
    Headers: X-Relay-Token: <FREEPBX_RELAY_TOKEN>
    Body:    {"to": "+E164_PHONE_NUMBER", "message": "Alert: service down"}
    Returns: {"status": "ok", "to": "+E164...", "sound": "akira-alert-NNNN"}

  GET /health
    Returns: {"status": "ok"}

Setup:
  Installed by deploy.sh (--setup-freepbx) to /usr/local/bin/freepbx-ami-relay.py
  Run as systemd service: openclaw-ami-relay.service
  Env: FREEPBX_RELAY_TOKEN (required), RELAY_PORT (default 18511)

Requirements on the FreePBX VM:
  apt install flite sox
  (both are used by generate_tts to produce 8kHz PCM WAV for Asterisk Playback)
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
import json, os, time, subprocess, shutil, sys

RELAY_TOKEN = os.environ.get("FREEPBX_RELAY_TOKEN", "")
RELAY_PORT  = int(os.environ.get("RELAY_PORT", "18511"))
SPOOL_DIR   = "/var/spool/asterisk/outgoing"
SOUNDS_DIR  = "/var/lib/asterisk/sounds/custom"
TRUNK       = os.environ.get("ASTERISK_TRUNK", "YOUR_TRUNK_NAME")  # e.g. "Twilio" or "VoIP.ms"
CALLER_ID   = os.environ.get("CALLER_ID", "Akira <+E164_CALLER_NUMBER>")
MAX_SOUND_AGE_SECS = 3600  # clean up TTS files older than 1 hour


def generate_tts(message: str, uid: str) -> str:
    """Generate a WAV file from text using flite + sox for Asterisk compatibility.
    Returns the sound name (without .wav) for Asterisk Playback."""
    sound_name = f"akira-alert-{uid}"
    raw_path   = os.path.join(SOUNDS_DIR, f"{sound_name}-raw.wav")
    final_path = os.path.join(SOUNDS_DIR, f"{sound_name}.wav")

    os.makedirs(SOUNDS_DIR, exist_ok=True)

    # Generate TTS with flite (any sample rate)
    subprocess.run(["flite", "-t", message, "-o", raw_path], check=True, capture_output=True)

    # Convert to Asterisk-expected format: 8kHz, mono, signed 16-bit PCM
    subprocess.run(
        ["sox", raw_path, "-r", "8000", "-c", "1", "-e", "signed-integer", "-b", "16", final_path],
        check=True, capture_output=True
    )
    os.remove(raw_path)

    # Ensure asterisk process can read it
    try:
        shutil.chown(final_path, "asterisk", "asterisk")
    except Exception:
        pass

    return sound_name


def originate_call(to: str, message: str) -> dict:
    """Write an Asterisk call file to trigger an outbound call."""
    uid = str(int(time.time() * 1000))

    sound_name = generate_tts(message, uid)

    # Asterisk call file — atomic write (tmp → final) so Asterisk doesn't
    # pick up a partial file.
    call_file = os.path.join(SPOOL_DIR, f"akira-{uid}.call")
    tmp_file  = call_file + ".tmp"

    content = (
        f"Channel: PJSIP/{to}@{TRUNK}\n"
        f"Application: Playback\n"
        f"Data: custom/{sound_name}\n"
        f"MaxRetries: 2\n"
        f"RetryTime: 30\n"
        f"WaitTime: 45\n"
        f"CallerID: {CALLER_ID}\n"
    )
    with open(tmp_file, "w") as f:
        f.write(content)

    try:
        shutil.chown(tmp_file, "asterisk", "asterisk")
    except Exception:
        pass

    os.rename(tmp_file, call_file)

    # Async cleanup of old TTS files
    _cleanup_old_sounds()

    return {"status": "ok", "to": to, "sound": sound_name, "call_file": call_file}


def _cleanup_old_sounds():
    """Remove TTS WAV files older than MAX_SOUND_AGE_SECS."""
    now = time.time()
    try:
        for f in os.listdir(SOUNDS_DIR):
            if f.startswith("akira-alert-"):
                path = os.path.join(SOUNDS_DIR, f)
                if os.path.isfile(path) and (now - os.path.getmtime(path)) > MAX_SOUND_AGE_SECS:
                    os.remove(path)
    except Exception:
        pass


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self._json(200, {"status": "ok"})
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path != "/call":
            self.send_error(404)
            return

        if not RELAY_TOKEN:
            self.send_error(500, "FREEPBX_RELAY_TOKEN not set")
            return

        if self.headers.get("X-Relay-Token") != RELAY_TOKEN:
            self.send_error(403, "Forbidden")
            return

        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length))
        except Exception:
            self.send_error(400, "Invalid JSON")
            return

        to      = str(body.get("to", "")).strip()
        message = str(body.get("message", "Alert from Akira")).strip()

        if not to:
            self.send_error(400, "Missing 'to'")
            return

        try:
            result = originate_call(to, message)
            self._json(200, result)
        except Exception as e:
            self._json(500, {"status": "error", "reason": str(e)})

    def _json(self, code: int, data: dict):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print(f"[ami-relay] {self.address_string()} — {fmt % args}", flush=True)


if __name__ == "__main__":
    if not RELAY_TOKEN:
        print("[ami-relay] ERROR: FREEPBX_RELAY_TOKEN environment variable not set", file=sys.stderr)
        sys.exit(1)
    print(f"[ami-relay] Listening on 0.0.0.0:{RELAY_PORT}", flush=True)
    server = HTTPServer(("0.0.0.0", RELAY_PORT), Handler)
    server.serve_forever()
