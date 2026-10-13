"""
Data lake push job (simulated).

Sends every file in <data lake>/inbox/<FIRM CODE>/ to the Salesforce trade import endpoint,
then moves it to processed/<FIRM>/ or failed/<FIRM>/. The firm code is the folder name.
The job does no parsing or matching: all logic lives in Salesforce.

Authentication:
  --auth sfcli  Reuses an org the Salesforce CLI is already logged into (quickest for a demo).
  --auth jwt    OAuth 2.0 JWT bearer flow through an External Client App (how a real
                scheduled job authenticates). Needs SF_CLIENT_ID, SF_USERNAME, SF_PRIVATE_KEY_FILE,
                and optionally SF_LOGIN_URL (default https://login.salesforce.com).

Examples:
  python push_job.py --lake ../datalake --once --auth sfcli --target-org tradeDemo
  python push_job.py --lake ../datalake --watch --interval 15 --auth jwt
"""
import argparse
import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import requests

ENDPOINT = "/services/apexrest/trade-import/v1/files"
ALLOWED_SUFFIXES = {".csv", ".txt"}
TIMEOUT = 60


class AuthError(Exception):
    pass


# ---------------------------------------------------------------- authentication
def auth_sfcli(target_org):
    """Access token and instance URL from the Salesforce CLI's stored login."""
    sf = shutil.which("sf")  # resolves sf.cmd on Windows
    if not sf:
        raise AuthError("Salesforce CLI (sf) not found on PATH.")
    proc = subprocess.run([sf, "org", "display", "--target-org", target_org, "--json"],
                          capture_output=True, text=True, timeout=120)
    try:
        result = json.loads(proc.stdout)["result"]
        return result["accessToken"], result["instanceUrl"].rstrip("/")
    except (ValueError, KeyError, TypeError):
        raise AuthError(f"Could not read the CLI login for '{target_org}': {proc.stderr.strip() or proc.stdout.strip()}")


def auth_jwt(env=os.environ):
    """OAuth 2.0 JWT bearer flow. Returns (access_token, instance_url)."""
    import jwt  # PyJWT; only needed for this mode

    missing = [k for k in ("SF_CLIENT_ID", "SF_USERNAME", "SF_PRIVATE_KEY_FILE") if not env.get(k)]
    if missing:
        raise AuthError("Missing environment variables: " + ", ".join(missing))
    login_url = env.get("SF_LOGIN_URL", "https://login.salesforce.com").rstrip("/")
    key = Path(env["SF_PRIVATE_KEY_FILE"]).read_text()
    assertion = jwt.encode(
        {"iss": env["SF_CLIENT_ID"], "sub": env["SF_USERNAME"], "aud": login_url,
         "exp": int(time.time()) + 180},
        key, algorithm="RS256")
    resp = requests.post(f"{login_url}/services/oauth2/token", timeout=TIMEOUT, data={
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion})
    if resp.status_code != 200:
        raise AuthError(f"JWT login failed ({resp.status_code}): {resp.text}")
    body = resp.json()
    return body["access_token"], body["instance_url"].rstrip("/")


# ---------------------------------------------------------------- push
def build_payload(firm, path):
    data = path.read_bytes()
    return {
        "sourceFirm": firm,
        "fileName": path.name,
        "fileHash": hashlib.sha256(data).hexdigest(),
        "content": base64.b64encode(data).decode("ascii"),
    }


def move(path, lake, outcome, firm, note=None):
    dest_dir = lake / outcome / firm
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    dest = dest_dir / f"{stamp}_{path.name}"
    shutil.move(str(path), dest)
    if note:
        dest.with_name(dest.name + ".error.txt").write_text(note, encoding="utf-8")
    return dest


def pending_files(lake):
    inbox = lake / "inbox"
    if not inbox.is_dir():
        return []
    files = []
    for firm_dir in sorted(p for p in inbox.iterdir() if p.is_dir()):
        for f in sorted(firm_dir.iterdir()):
            if f.is_file() and f.suffix.lower() in ALLOWED_SUFFIXES:
                files.append((firm_dir.name.upper(), f))
    return files


class Pusher:
    def __init__(self, authenticate, session=None, log=print):
        self.authenticate = authenticate
        self.session = session or requests.Session()
        self.log = log
        self.token = self.instance = None

    def _post(self, payload):
        if not self.token:
            self.token, self.instance = self.authenticate()
        resp = self.session.post(f"{self.instance}{ENDPOINT}", json=payload, timeout=TIMEOUT,
                                 headers={"Authorization": f"Bearer {self.token}"})
        if resp.status_code == 401:  # token expired: log in again once
            self.token, self.instance = self.authenticate()
            resp = self.session.post(f"{self.instance}{ENDPOINT}", json=payload, timeout=TIMEOUT,
                                     headers={"Authorization": f"Bearer {self.token}"})
        return resp

    def push_once(self, lake):
        """Returns counts by outcome. Network/5xx failures leave the file in the inbox for the next run."""
        counts = {"sent": 0, "duplicate": 0, "failed": 0, "retry": 0}
        for firm, path in pending_files(lake):
            try:
                resp = self._post(build_payload(firm, path))
            except (requests.RequestException, AuthError) as e:
                counts["retry"] += 1
                self.log(f"RETRY   {firm}/{path.name}: {e}")
                continue
            try:
                body = resp.json()
            except ValueError:
                body = {"error": resp.text[:500]}
            if resp.status_code in (200, 201):
                move(path, lake, "processed", firm)
                key = "duplicate" if body.get("duplicate") else "sent"
                counts[key] += 1
                self.log(f"{'DUPLICATE' if key == 'duplicate' else 'SENT':9} {firm}/{path.name} -> batch "
                         f"{body.get('batchId')} ({body.get('status')})")
            elif 400 <= resp.status_code < 500:
                move(path, lake, "failed", firm, note=f"HTTP {resp.status_code}: {body.get('error', body)}")
                counts["failed"] += 1
                self.log(f"FAILED  {firm}/{path.name}: HTTP {resp.status_code} {body.get('error', body)}")
            else:
                counts["retry"] += 1
                self.log(f"RETRY   {firm}/{path.name}: HTTP {resp.status_code} {body.get('error', body)}")
        return counts


def main(argv=None):
    ap = argparse.ArgumentParser(description="Push data lake trade files to Salesforce.")
    ap.add_argument("--lake", required=True, type=Path, help="Data lake folder containing inbox/<FIRM>/ files")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--once", action="store_true", help="Process the inbox once and exit (for schedulers)")
    mode.add_argument("--watch", action="store_true", help="Keep polling the inbox")
    ap.add_argument("--interval", type=int, default=15, help="Seconds between polls with --watch")
    ap.add_argument("--auth", choices=["sfcli", "jwt"], default="sfcli")
    ap.add_argument("--target-org", default="tradeDemo", help="CLI alias, for --auth sfcli")
    args = ap.parse_args(argv)

    authenticate = (lambda: auth_sfcli(args.target_org)) if args.auth == "sfcli" else auth_jwt
    pusher = Pusher(authenticate)
    if args.once:
        counts = pusher.push_once(args.lake)
        print(f"Done: {counts}")
        return 1 if counts["failed"] else 0
    print(f"Watching {args.lake / 'inbox'} every {args.interval}s. Ctrl+C to stop.")
    try:
        while True:
            pusher.push_once(args.lake)
            time.sleep(args.interval)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
