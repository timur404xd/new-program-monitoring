#!/usr/bin/env python3
"""
intigriti_status_monitor.py
Watches specific Intigriti programs (names listed in watched_programs.txt) and
sends a Telegram alert immediately whenever their status changes, with a special
UNSUSPENDED / SUSPENDED headline for those transitions, plus a silent
heartbeat at most once every 6 hours when nothing changed.
State lives in state/ and is committed back by the workflow.
"""

import json
import os
import sys
import time
from pathlib import Path

import requests

API_BASE = "https://api.intigriti.com/external/researcher/v1"
WATCH_FILE = Path(os.environ.get("WATCH_FILE", "watched_programs.txt"))
STATE_FILE = Path("state/intigriti_program_status.json")  # {"<program id>": "<status>"}
HEARTBEAT_FILE = Path("state/intigriti_status_last_heartbeat")
HEARTBEAT_INTERVAL_SECS = 6 * 3600


def env(name):
    value = os.environ.get(name)
    if not value:
        sys.exit(f"ERROR: set {name} env var")
    return value


INTIGRITI_TOKEN = env("INTIGRITI_API_TOKEN")
TELEGRAM_BOT_TOKEN = env("TELEGRAM_BOT_TOKEN")
TELEGRAM_CHAT_ID = env("TELEGRAM_CHAT_ID")


def send_telegram(message, silent=False):
    requests.post(
        f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage",
        data={
            "chat_id": TELEGRAM_CHAT_ID,
            "parse_mode": "Markdown",
            "disable_notification": "true" if silent else "false",
            "text": message,
        },
        timeout=30,
    )


def send_heartbeat_if_due(current):
    now = int(time.time())
    try:
        last = int(HEARTBEAT_FILE.read_text().strip())
    except (FileNotFoundError, ValueError):
        last = 0
    if now - last >= HEARTBEAT_INTERVAL_SECS:
        summary = ", ".join(f"{p['name']}: {p['status']}" for p in current.values())
        send_telegram(
            f"✅ Intigriti status check OK at {time.strftime('%H:%M UTC', time.gmtime())}: "
            f"no changes ({summary or 'nothing watched'})",
            silent=True,
        )
        HEARTBEAT_FILE.write_text(str(now))


def fetch_all_programs():
    headers = {"Authorization": f"Bearer {INTIGRITI_TOKEN}"}
    records, offset, limit = [], 0, 100
    while True:
        resp = requests.get(
            f"{API_BASE}/programs",
            headers=headers,
            params={"limit": limit, "offset": offset},
            timeout=30,
        )
        try:
            page = resp.json()
        except ValueError:
            page = None
        if not isinstance(page, dict) or "records" not in page:
            sys.exit(f"ERROR: unexpected API response ({resp.status_code}): {resp.text[:300]}")
        batch = page["records"]
        records.extend(batch)
        offset += limit
        if len(batch) < limit:
            return records


def load_watch_list():
    if not WATCH_FILE.is_file():
        sys.exit(f"ERROR: {WATCH_FILE} not found")
    entries = []
    for line in WATCH_FILE.read_text().splitlines():
        line = line.split(" #", 1)[0] if line.strip().startswith("http") else line.split("#", 1)[0]
        line = line.strip()
        if line:
            entries.append(line.lower())
    return entries


def normalize_url(url):
    url = url.split("?", 1)[0].split("#", 1)[0].rstrip("/")
    if url.endswith("/detail"):
        url = url[: -len("/detail")]
    return url


def matches(rec, entry):
    """Entry is either a pasted program page URL, or a case-insensitive
    substring of the program name / program link."""
    link = ((rec.get("webLinks") or {}).get("detail") or "").lower()
    if entry.startswith("http"):
        return normalize_url(entry) in normalize_url(link)
    return entry in (rec.get("name") or "").lower() or entry in link


def main():
    watch = load_watch_list()
    if not watch:
        print(f"No programs in {WATCH_FILE}, nothing to do.")
        return

    # Current status of watched programs only: {id: {name, status, link}}
    current = {}
    unmatched = set(watch)
    for rec in fetch_all_programs():
        hit = [e for e in watch if matches(rec, e)]
        if not hit:
            continue
        unmatched -= set(hit)
        current[rec["id"]] = {
            "name": rec["name"],
            "status": (rec.get("status") or {}).get("value") or "Unknown",
            "link": (rec.get("webLinks") or {}).get("detail", ""),
        }

    for entry in sorted(unmatched):
        print(f"WARNING: no program matched (or not visible to you): {entry}", file=sys.stderr)

    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)

    # First run: store baseline, one summary message, no alerts
    if not STATE_FILE.is_file() or STATE_FILE.stat().st_size == 0:
        STATE_FILE.write_text(json.dumps({i: p["status"] for i, p in current.items()}, indent=2))
        summary = "\n".join(f"• {p['name']}: {p['status']}" for p in current.values())
        if unmatched:
            summary += "\n\n⚠️ No match for: " + ", ".join(sorted(unmatched))
        send_telegram(
            f"✅ Intigriti status monitor started — watching {len(current)} programs\n\n{summary}"
        )
        HEARTBEAT_FILE.write_text(str(int(time.time())))
        return

    previous = json.loads(STATE_FILE.read_text())

    alerted = False
    # New watch entries (not in previous) get a silent baseline
    for pid, p in current.items():
        old = previous.get(pid)
        if old is None or old == p["status"]:
            continue
        new = p["status"]
        if old == "Suspended" and new == "Open":
            header = "🟢 *UNSUSPENDED*"
        elif new == "Suspended":
            header = "🔴 *SUSPENDED*"
        else:
            header = "🔄 *Status change*"
        send_telegram(f"{header}\n*{p['name']}*\n{old} → {new}\n\n{p['link']}")
        alerted = True
        time.sleep(1)

    # Merge: keep old entries (flaky response), overwrite with current
    previous.update({i: p["status"] for i, p in current.items()})
    STATE_FILE.write_text(json.dumps(previous, indent=2))

    # No heartbeat on a run that already sent real alerts
    if not alerted:
        send_heartbeat_if_due(current)


if __name__ == "__main__":
    main()
