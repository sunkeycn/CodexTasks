#!/usr/bin/env python3
"""Optional Codex command hook. Writes metadata only; stdout never controls Codex."""
import argparse
import datetime as dt
import hashlib
import fcntl
import http.client
import json
import os
from pathlib import Path
import shlex
import sys
import tempfile
from urllib.parse import urlsplit

STATES = {"UserPromptSubmit": "running", "Stop": "completed", "Interrupt": "interrupted"}


def notify(record, endpoint_file):
    """Bounded, loopback-only best effort; never inherit an HTTP proxy."""
    try:
        if endpoint_file.is_symlink() or endpoint_file.stat().st_size > 4096:
            return
        endpoint = json.loads(endpoint_file.read_text())
        if not isinstance(endpoint, dict):
            return
        url = urlsplit(endpoint.get("url", ""))
        token = endpoint.get("token", "")
        if (endpoint.get("version") != 1 or url.scheme != "http" or url.hostname != "127.0.0.1"
                or url.path != "/v1/events" or not url.port or url.username or url.password or url.query or url.fragment
                or not isinstance(token, str) or len(token) != 64 or not all(c in "0123456789abcdefABCDEF" for c in token)):
            return
        connection = http.client.HTTPConnection("127.0.0.1", url.port, timeout=0.2)
        try:
            body = json.dumps({"version": 1, "kind": "hook", "hook": record}).encode()
            connection.request("POST", "/v1/events", body, {"Authorization": "Bearer " + token, "Content-Type": "application/json"})
            connection.getresponse().close()
        finally:
            connection.close()
    except (OSError, ValueError, TypeError, http.client.HTTPException):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--print-config", action="store_true", help="Print a hooks.json fragment; does not install it")
    parser.add_argument("--status-directory", type=Path, default=Path.home() / ".codex/codex-tasks-status")
    parser.add_argument("--endpoint-file", type=Path, default=Path.home() / ".codex/codex-tasks-bridge/endpoint.json")
    args = parser.parse_args()
    if args.print_config:
        command = shlex.join([sys.executable, str(Path(__file__).resolve())])
        print(json.dumps({"hooks": {event: [{"hooks": [{"type": "command", "command": command, "timeout": 3, "async": True}]}] for event in STATES}}, ensure_ascii=False, indent=2))
        return
    # Bound input and persist only explicitly selected metadata, never prompts or tool output.
    payload = json.loads(sys.stdin.buffer.read(8 * 1024 * 1024))
    if not isinstance(payload, dict):
        return
    event = payload.get("hook_event_name")
    session, turn, cwd = (payload.get(key) for key in ("session_id", "turn_id", "cwd"))
    if event not in STATES or not all(isinstance(value, str) and 0 < len(value) <= 4096 for value in (session, turn, cwd)) or not os.path.isabs(cwd):
        return
    # Subagent callbacks share the parent's session id; they must not complete the main task.
    if payload.get("agent_id") or payload.get("agent_type"):
        return
    record = {"version": 1, "sessionID": session, "turnID": turn, "cwd": str(Path(cwd).resolve()),
              "event": event, "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")}
    target = args.status_directory.expanduser()
    target.mkdir(mode=0o700, parents=True, exist_ok=True)
    filename = hashlib.sha256(session.encode()).hexdigest() + ".json"
    # Async callbacks can overlap. Serialize replacement and never regress a
    # terminal state to a delayed start from the same turn.
    lock_path = target / ("." + filename + ".lock")
    with os.fdopen(os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        destination = target / filename
        try:
            previous = json.loads(destination.read_text()) if not destination.is_symlink() and destination.stat().st_size <= 16 * 1024 else {}
        except (OSError, ValueError, TypeError):
            previous = {}
        if not isinstance(previous, dict):
            previous = {}
        if previous.get("turnID") == turn and previous.get("event") in ("Stop", "Interrupt"):
            return
        save_record(record, target, filename)
    notify(record, args.endpoint_file.expanduser())


def save_record(record, target, filename):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", prefix=".status-", dir=target, delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(record, stream, ensure_ascii=False)
        os.replace(temporary, target / filename)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError):
        # Telemetry must never block a user's prompt or alter a tool's permission decision.
        pass
