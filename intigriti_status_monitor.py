#!/usr/bin/env python3
"""
intigriti_status_monitor.py
Watches specific Intigriti programs and sends an alert immediately whenever their status
changes, with a special UNSUSPENDED / SUSPENDED headline for those transitions.

Watchlist (which programs to watch) -- either of:
  Discord  a #status-watchlist channel, read by a bot at the start of every run (nothing
           has to stay running). Set DISCORD_BOT_TOKEN + DISCORD_STATUS_WATCHLIST_CHANNEL_ID,
           and ideally DISCORD_OWNER_ID so only your own messages count. One entry per line,
           same syntax as watched_programs.txt:
               pendo
               https://app.intigriti.com/researcher/programs/<company>/<program>/detail
           Lines starting with # are ignored. Delete a message to stop watching it; edit it
           to change it. The bot reacts ✅ when every entry in a message matched a program,
           and ❌ when one didn't (the closest program names are posted once, too).
           If Discord can't be read, the last watchlist read from it is used instead.
  File     watched_programs.txt (used when the Discord watchlist is not configured)

Alerts (configure one or both):
  Discord  DISCORD_WEBHOOK_URL            channel for status changes (embeds: green when a
                                          program reopens, red when it is suspended)
           DISCORD_HEARTBEAT_WEBHOOK_URL  optional channel for the startup notice, warnings
                                          and the daily heartbeat (defaults to the main one)
           DISCORD_USERNAME               optional display name (default "Intigriti Status")
  Telegram TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID

A silent heartbeat is sent once a day, on the first run at or after HEARTBEAT_HOUR:00 in
HEARTBEAT_TZ (default 00:00 Africa/Cairo).
State lives in state/ and is committed back by the workflow.
"""

import difflib
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote
from zoneinfo import ZoneInfo

import requests

API_BASE = os.environ.get("INTIGRITI_API_BASE", "https://api.intigriti.com/external/researcher/v1")
WATCH_FILE = Path(os.environ.get("WATCH_FILE", "watched_programs.txt"))
STATE_FILE = Path("state/intigriti_program_status.json")  # {"<program id>": "<status>"}
HEARTBEAT_FILE = Path("state/intigriti_status_last_heartbeat")
UNMATCHED_FILE = Path("state/intigriti_status_unmatched.json")  # entries already warned about
WATCH_CACHE_FILE = Path("state/intigriti_status_watchlist_cache.json")  # last Discord watchlist
HEARTBEAT_TZ = ZoneInfo(os.environ.get("HEARTBEAT_TZ", "Africa/Cairo"))
HEARTBEAT_HOUR = int(os.environ.get("HEARTBEAT_HOUR", "0"))  # 0 = 12 am

TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
DISCORD_WEBHOOK_URL = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
DISCORD_HEARTBEAT_WEBHOOK_URL = (os.environ.get("DISCORD_HEARTBEAT_WEBHOOK_URL", "").strip()
                                 or DISCORD_WEBHOOK_URL)
DISCORD_USERNAME = os.environ.get("DISCORD_USERNAME", "Intigriti Status")
DISCORD_API = os.environ.get("DISCORD_API", "https://discord.com/api/v10")
DISCORD_BOT_TOKEN = os.environ.get("DISCORD_BOT_TOKEN", "").strip()
DISCORD_WATCH_CHANNEL = os.environ.get("DISCORD_STATUS_WATCHLIST_CHANNEL_ID", "").strip()
DISCORD_OWNER_ID = os.environ.get("DISCORD_OWNER_ID", "").strip()
DISCORD_UA = "DiscordBot (https://github.com, 1.0)"
DISCORD_FLAG_SUPPRESS_EMBEDS = 1 << 2
DISCORD_FLAG_SILENT = 1 << 12  # posts without a push/sound notification
GREEN, RED, ORANGE, BLUE = 0x2ECC71, 0xE74C3C, 0xE67E22, 0x5865F2


def env(name):
    value = os.environ.get(name)
    if not value:
        sys.exit(f"ERROR: set {name} env var")
    return value


INTIGRITI_TOKEN = env("INTIGRITI_API_TOKEN")
if not DISCORD_WEBHOOK_URL and not (TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID):
    sys.exit("ERROR: set DISCORD_WEBHOOK_URL and/or TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID")


# --------------------------------------------------------------------------- notifications
def send_telegram(message, silent=False):
    """True when sent, or when Telegram isn't configured."""
    if not (TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID):
        return True
    try:
        r = requests.post(
            f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage",
            data={
                "chat_id": TELEGRAM_CHAT_ID,
                "parse_mode": "Markdown",
                "disable_notification": "true" if silent else "false",
                "text": message,
            },
            timeout=30,
        )
        return r.ok
    except requests.RequestException as e:
        print(f"WARN: telegram send failed: {e}", file=sys.stderr)
        return False


def discord_post(webhook, payload):
    """POST one message to a Discord webhook; waits out rate limits. True on success."""
    if not webhook:
        return True
    for _ in range(4):
        try:
            r = requests.post(webhook, params={"wait": "true"}, json=payload,
                              headers={"User-Agent": DISCORD_UA}, timeout=30)
        except requests.RequestException as e:
            print(f"WARN: discord send failed: {e}", file=sys.stderr)
            return False
        if r.status_code == 429:
            try:
                wait = float(r.json().get("retry_after", 2))
            except ValueError:
                wait = 2.0
            time.sleep(min(wait, 30) + 0.5)
            continue
        if r.ok:
            return True
        print(f"WARN: discord send failed: HTTP {r.status_code} {r.text[:300]}", file=sys.stderr)
        return False
    print("WARN: discord send failed: still rate-limited after retries", file=sys.stderr)
    return False


def _plain(text):
    """Telegram-Markdown text -> plain text for Discord status messages."""
    return text.replace("*", "")


def notify_status(text, silent=False):
    """Startup notice, warnings, heartbeat: Discord status channel + Telegram."""
    flags = DISCORD_FLAG_SUPPRESS_EMBEDS | (DISCORD_FLAG_SILENT if silent else 0)
    ok = discord_post(DISCORD_HEARTBEAT_WEBHOOK_URL, {
        "username": DISCORD_USERNAME, "content": _plain(text)[:1990], "flags": flags,
        "allowed_mentions": {"parse": []}})
    return send_telegram(text, silent=silent) and ok


def notify_program(tg_text, title, link, description, color, footer, silent=False):
    """Per-program message: Discord embed in the status-change channel + Telegram."""
    embed = {"title": title[:256], "description": description, "color": color,
             "footer": {"text": footer}, "timestamp": datetime.now(timezone.utc).isoformat()}
    if link.startswith(("http://", "https://")):
        embed["url"] = link
    ok = discord_post(DISCORD_WEBHOOK_URL, {
        "username": DISCORD_USERNAME, "embeds": [embed], "allowed_mentions": {"parse": []},
        "flags": DISCORD_FLAG_SILENT if silent else 0})
    return send_telegram(tg_text, silent=silent) and ok


def send_heartbeat_if_due(current):
    """Once per day: the first run at/after today's HEARTBEAT_HOUR:00 in HEARTBEAT_TZ."""
    now = int(time.time())
    try:
        last = int(HEARTBEAT_FILE.read_text().strip())
    except (FileNotFoundError, ValueError):
        last = 0
    local_now = datetime.fromtimestamp(now, HEARTBEAT_TZ)
    slot = local_now.replace(hour=HEARTBEAT_HOUR, minute=0, second=0, microsecond=0)
    if local_now < slot or last >= slot.timestamp():
        return
    summary = ", ".join(f"{p['name']}: {p['status']}" for p in current.values())
    if notify_status(
        f"✅ Daily Intigriti status check at {local_now.strftime('%H:%M %Z')}: monitor alive "
        f"({summary or 'nothing watched'})",
        silent=True,
    ):
        HEARTBEAT_FILE.write_text(str(now))


# --------------------------------------------------------------------------- intigriti
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


# --------------------------------------------------------------------------- watchlist
def parse_entries(text):
    """Watchlist text (file or Discord message) -> lowercase entries, comments dropped."""
    entries = []
    for line in text.splitlines():
        line = re.sub(r"<(https?://[^>\s]+)>", r"\1", line.strip())  # Discord's <link> form
        line = line.split(" #", 1)[0] if line.startswith("http") else line.split("#", 1)[0]
        line = line.strip().strip("`").strip()
        if line:
            entries.append(line.lower())
    return entries


def discord_api(method, path):
    """Discord REST call as the bot -> (status, json-or-None). Waits out rate limits."""
    headers = {"Authorization": f"Bot {DISCORD_BOT_TOKEN}", "User-Agent": DISCORD_UA}
    for _ in range(5):
        try:
            r = requests.request(method, DISCORD_API + path, headers=headers, timeout=30)
        except requests.RequestException as e:
            print(f"WARN: Discord API {method} {path} failed: {e}", file=sys.stderr)
            return None, None
        if r.status_code == 429:
            try:
                wait = float(r.json().get("retry_after", 1))
            except ValueError:
                wait = 1.0
            time.sleep(min(wait, 30) + 0.25)
            continue
        try:
            body = r.json() if r.content else None
        except ValueError:
            body = None
        return r.status_code, body
    return 429, None


def fetch_discord_watchlist():
    """[(message, entries)] from the watchlist channel, oldest first; None if unreadable."""
    msgs, before = [], None
    while True:
        q = "?limit=100" + (f"&before={before}" if before else "")
        st, page = discord_api("GET", f"/channels/{DISCORD_WATCH_CHANNEL}/messages{q}")
        if st != 200 or not isinstance(page, list):
            hint = {401: "bad DISCORD_BOT_TOKEN",
                    403: "bot can't see the channel (check View Channel / Read Message History)",
                    404: "wrong DISCORD_STATUS_WATCHLIST_CHANNEL_ID"}.get(st, "")
            print(f"WARN: couldn't read the Discord status watchlist (HTTP {st}) {hint}",
                  file=sys.stderr)
            return None
        msgs.extend(page)
        if len(page) < 100:
            break
        before = page[-1]["id"]
    msgs.reverse()

    out, considered, blank = [], 0, 0
    for msg in msgs:
        author = msg.get("author") or {}
        if author.get("bot") or (DISCORD_OWNER_ID and author.get("id") != DISCORD_OWNER_ID):
            continue
        considered += 1
        content = msg.get("content") or ""
        if not content.strip():
            blank += 1
            continue
        out.append((msg, parse_entries(content)))
    if considered and blank == considered:
        print("WARN: every watchlist message came back empty -- turn on the bot's "
              "MESSAGE CONTENT INTENT in the Discord Developer Portal", file=sys.stderr)
        return None
    return out


def mark_message(msg, ok):
    """React ✅ / ❌ once per message (and swap it when the result changes)."""
    want, other = ("✅", "❌") if ok else ("❌", "✅")
    mine = {(r.get("emoji") or {}).get("name") for r in msg.get("reactions") or [] if r.get("me")}
    base = f"/channels/{DISCORD_WATCH_CHANNEL}/messages/{msg['id']}/reactions"
    if want not in mine:
        st, _ = discord_api("PUT", f"{base}/{quote(want)}/@me")
        if st not in (200, 204):
            print(f"WARN: couldn't react on watchlist message {msg['id']} (HTTP {st}); "
                  "give the bot the Add Reactions permission", file=sys.stderr)
        time.sleep(0.3)
    if other in mine:
        discord_api("DELETE", f"{base}/{quote(other)}/@me")
        time.sleep(0.3)


def load_watch_list():
    """-> (entries, discord messages or None, origin)."""
    if DISCORD_BOT_TOKEN and DISCORD_WATCH_CHANNEL:
        msgs = fetch_discord_watchlist()
        if msgs is None:
            try:
                cached = json.loads(WATCH_CACHE_FILE.read_text())
            except (FileNotFoundError, ValueError):
                cached = None
            if cached:
                print(f"WARN: using the last watchlist read from Discord ({len(cached)} entries)",
                      file=sys.stderr)
                return cached, None, "discord-cache"
            sys.exit("ERROR: couldn't read the Discord status watchlist and there is no cached copy")
        entries = list(dict.fromkeys(e for _, ents in msgs for e in ents))
        WATCH_CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
        WATCH_CACHE_FILE.write_text(json.dumps(entries, indent=1))
        return entries, msgs, "discord"

    if not WATCH_FILE.is_file():
        sys.exit(f"ERROR: {WATCH_FILE} not found (and no Discord watchlist configured)")
    return list(dict.fromkeys(parse_entries(WATCH_FILE.read_text()))), None, "file"


def normalize_url(url):
    url = url.split("?", 1)[0].split("#", 1)[0].rstrip("/")
    if url.endswith("/detail"):
        url = url[: -len("/detail")]
    return url


def url_key(url):
    """'https://app.intigriti.com/researcher/programs/co/prog/detail?x' -> 'co/prog'"""
    path = normalize_url(url)
    if "/programs/" in path:
        return path.split("/programs/", 1)[1]
    return "/".join(path.split("/")[-2:])


def matches(rec, entry):
    """Entry is either a pasted program page URL, or a case-insensitive
    substring of the program name / program link."""
    link = ((rec.get("webLinks") or {}).get("detail") or "").lower()
    if entry.startswith("http"):
        return url_key(entry) in link
    return entry in (rec.get("name") or "").lower() or entry in link


def suggest(records, entry, n=3):
    """Closest programs to an unmatched entry, as 'Name (link)' strings."""
    key = url_key(entry) if entry.startswith("http") else entry
    scored = []
    for rec in records:
        name = (rec.get("name") or "").lower()
        link = ((rec.get("webLinks") or {}).get("detail") or "").lower()
        score = max(
            difflib.SequenceMatcher(None, key, name).ratio(),
            difflib.SequenceMatcher(None, key, link).ratio(),
            difflib.SequenceMatcher(None, key.split("/")[-1], name).ratio(),
        )
        scored.append((score, f"{rec.get('name')} ({link or 'no link'})"))
    scored.sort(reverse=True)
    return [text for score, text in scored[:n] if score > 0.3]


# --------------------------------------------------------------------------- main
def main():
    watch, discord_msgs, origin = load_watch_list()
    print(f"Watchlist: {len(watch)} entr{'y' if len(watch) == 1 else 'ies'} from {origin}")
    if not watch:
        print("Nothing to watch.")
        return

    # Current status of watched programs only: {id: {name, status, link}}
    current = {}
    unmatched = set(watch)
    all_records = fetch_all_programs()
    for rec in all_records:
        hit = [e for e in watch if matches(rec, e)]
        if not hit:
            continue
        unmatched -= set(hit)
        current[rec["id"]] = {
            "name": rec["name"],
            "status": (rec.get("status") or {}).get("value") or "Unknown",
            "link": (rec.get("webLinks") or {}).get("detail", ""),
        }

    # ✅ / ❌ on each Discord watchlist message
    for msg, ents in discord_msgs or []:
        if ents:
            mark_message(msg, not (set(ents) & unmatched))

    hints = {}
    for entry in sorted(unmatched):
        hints[entry] = suggest(all_records, entry)
        print(f"WARNING: no program matched (or not visible to you): {entry}", file=sys.stderr)
        for h in hints[entry]:
            print(f"    closest: {h}", file=sys.stderr)

    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    first_run = not STATE_FILE.is_file() or STATE_FILE.stat().st_size == 0

    # Warn once per unmatched entry (re-warns if you edit the entry)
    try:
        warned = set(json.loads(UNMATCHED_FILE.read_text()))
    except (FileNotFoundError, ValueError):
        warned = set()
    new_unmatched = sorted(unmatched - warned)
    if new_unmatched and not first_run:
        lines = ["⚠️ Intigriti status monitor: no program matched (or not visible to you):"]
        for e in new_unmatched:
            lines.append(f"• {e}")
            if hints[e]:
                lines.append("   closest: " + "; ".join(hints[e]))
        notify_status("\n".join(lines))
    UNMATCHED_FILE.write_text(json.dumps(sorted(unmatched)))

    # First run: store baseline, one summary message, no alerts
    if first_run:
        STATE_FILE.write_text(json.dumps({i: p["status"] for i, p in current.items()}, indent=2))
        summary = "\n".join(f"• {p['name']}: {p['status']}" for p in current.values())
        for entry in sorted(unmatched):
            summary += f"\n\n⚠️ No match for: {entry}"
            if hints[entry]:
                summary += "\nClosest: " + "; ".join(hints[entry])
            else:
                summary += "\nNo similar program found in your Intigriti program list."
        notify_status(
            f"✅ Intigriti status monitor started — watching {len(current)} programs\n\n{summary}"
        )
        HEARTBEAT_FILE.write_text(str(int(time.time())))  # next heartbeat at the coming midnight
        return

    previous = json.loads(STATE_FILE.read_text())

    for pid, p in current.items():
        old = previous.get(pid)
        if old is None:
            # newly watched: silent baseline message, then track it
            notify_program(f"➕ Now watching *{p['name']}*: {p['status']}",
                           f"➕ {p['name']}", p["link"], f"Now watching · status: **{p['status']}**",
                           BLUE, "Intigriti status watch", silent=True)
            previous[pid] = p["status"]
            continue
        if old == p["status"]:
            continue
        new = p["status"]
        if old == "Suspended" and new == "Open":
            header, title, color = "🟢 *UNSUSPENDED*", "🟢 UNSUSPENDED", GREEN
        elif new == "Suspended":
            header, title, color = "🔴 *SUSPENDED*", "🔴 SUSPENDED", RED
        else:
            header, title, color = "🔄 *Status change*", "🔄 Status change", ORANGE
        if notify_program(f"{header}\n*{p['name']}*\n{old} → {new}\n\n{p['link']}",
                          f"{title}: {p['name']}", p["link"], f"**{old} → {new}**", color,
                          "Intigriti status change"):
            previous[pid] = new  # only advance once the alert went out (else retried next run)
        time.sleep(1)

    # Merge: entries missing from this response (flaky API) keep their old status
    STATE_FILE.write_text(json.dumps(previous, indent=2))

    # Daily heartbeat, sent at 12 am even if this run also sent alerts
    send_heartbeat_if_due(current)


if __name__ == "__main__":
    main()
