#!/bin/bash
# bugcrowd_monitor.sh
# Monitors Bugcrowd's public program directory (bug_bounty + vdp categories)
# for new programs and sends alerts to Discord and/or Telegram. No auth required.
# Sends a silent daily heartbeat on the first run at/after HEARTBEAT_HOUR:00
# in HEARTBEAT_TZ (default 00:00 Africa/Cairo).

set -euo pipefail

export LC_ALL=C

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
# Discord: new-program alerts go to DISCORD_WEBHOOK_URL; startup notice and heartbeat go to
# DISCORD_HEARTBEAT_WEBHOOK_URL (falls back to DISCORD_WEBHOOK_URL when not set).
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
DISCORD_HEARTBEAT_WEBHOOK_URL="${DISCORD_HEARTBEAT_WEBHOOK_URL:-$DISCORD_WEBHOOK_URL}"
DISCORD_USERNAME="${DISCORD_USERNAME:-Bugcrowd Programs}"
if [[ -z "$DISCORD_WEBHOOK_URL" && ( -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ) ]]; then
  echo "ERROR: set DISCORD_WEBHOOK_URL and/or TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID" >&2
  exit 1
fi

STATE_DIR="state"
STATE_FILE="${STATE_DIR}/known_bugcrowd_programs.json"
HEARTBEAT_FILE="${STATE_DIR}/bugcrowd_last_heartbeat"
HEARTBEAT_TZ="${HEARTBEAT_TZ:-Africa/Cairo}"
HEARTBEAT_HOUR="${HEARTBEAT_HOUR:-0}"  # 0 = 12 am
BASE_URL="https://bugcrowd.com/engagements-us.json"
CATEGORIES=("bug_bounty" "vdp")

mkdir -p "$STATE_DIR"

# Returns success without doing anything when Telegram isn't configured.
send_telegram() {
  local message="$1"
  local silent="${2:-false}"
  if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
    return 0
  fi
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d parse_mode="Markdown" \
    -d disable_notification="${silent}" \
    --data-urlencode text="${message}" > /dev/null
}

# POST a JSON payload to a Discord webhook; waits out rate limits. Non-zero on failure.
discord_post() {
  local webhook="$1" payload="$2" code body sep="?"
  [[ -z "$webhook" ]] && return 0
  [[ "$webhook" == *\?* ]] && sep="&"
  body=$(mktemp)
  for _ in 1 2 3 4; do
    code=$(curl -s -o "$body" -w '%{http_code}' -X POST \
      -H "Content-Type: application/json" \
      -H "User-Agent: program-monitor (https://github.com, 1.0)" \
      --data-binary @- "${webhook}${sep}wait=true" <<< "$payload") || code=000
    if [[ "$code" == "429" ]]; then
      sleep "$(jq -r '(.retry_after // 2) | ceil' "$body" 2>/dev/null || echo 2)"
      continue
    fi
    if [[ "$code" == 2* ]]; then
      rm -f "$body"
      return 0
    fi
    echo "WARN: discord send failed: HTTP ${code} $(head -c 300 "$body")" >&2
    rm -f "$body"
    return 1
  done
  echo "WARN: discord send failed: still rate-limited after retries" >&2
  rm -f "$body"
  return 1
}

# Startup notice / heartbeat: Discord status channel (if set) + Telegram (if set).
# Second argument "true" sends it silently (no sound/vibration).
notify_status() {
  local text="$1" silent="${2:-false}" flags=4
  [[ "$silent" == "true" ]] && flags=4100   # 4 = no link previews, 4096 = silent
  if [[ -n "$DISCORD_HEARTBEAT_WEBHOOK_URL" ]]; then
    discord_post "$DISCORD_HEARTBEAT_WEBHOOK_URL" "$(jq -n --arg u "$DISCORD_USERNAME" \
      --arg c "${text:0:1990}" --argjson f "$flags" \
      '{username: $u, content: $c, flags: $f, allowed_mentions: {parse: []}}')" || true
  fi
  send_telegram "$text" "$silent"
}

# Fetches every page for a single category value
fetch_category() {
  local category="$1"
  local all_records="[]"
  local page=1
  local count
  local page_limit=24
  local resp

  while true; do
    resp=$(curl -s "${BASE_URL}?category=${category}&page=${page}&sort_by=promoted&sort_direction=desc")

    if ! echo "$resp" | jq -e '.engagements' > /dev/null 2>&1; then
      echo "ERROR: unexpected response for category=${category} page=${page}: $resp" >&2
      exit 1
    fi

    records=$(echo "$resp" | jq '.engagements')
    count=$(echo "$records" | jq 'length')
    all_records=$(jq -s 'add' <(echo "$all_records") <(echo "$records"))
    page=$((page + 1))

    [[ "$count" -lt "$page_limit" ]] && break
  done

  echo "$all_records"
}

# Loops both categories and merges, deduping on briefUrl so overlap
# (or a filter that behaves unexpectedly) never produces duplicates.
fetch_all_engagements() {
  local merged="[]"
  local cat_records

  for cat in "${CATEGORIES[@]}"; do
    cat_records=$(fetch_category "$cat")
    merged=$(jq -s 'add' <(echo "$merged") <(echo "$cat_records"))
  done

  merged=$(echo "$merged" | jq 'unique_by(.briefUrl)')

  echo "{\"engagements\": $merged}"
}

# briefUrl is the stable dedupe key (no numeric id in this feed)
build_alert_message() {
  local record="$1"
  local name tagline brief_url full_url reward_summary industry access_status service_level engagement_type

  name=$(echo "$record" | jq -r '.name')
  tagline=$(echo "$record" | jq -r '.tagline // empty' | head -c 200)
  brief_url=$(echo "$record" | jq -r '.briefUrl')
  full_url="https://bugcrowd.com${brief_url}"
  reward_summary=$(echo "$record" | jq -r '.rewardSummary.summary // "Unknown"')
  industry=$(echo "$record" | jq -r '.industryName // "Unknown"')
  access_status=$(echo "$record" | jq -r '.accessStatus // "Unknown"')
  service_level=$(echo "$record" | jq -r '.serviceLevel // "Unknown"')
  engagement_type=$(echo "$record" | jq -r '.productEngagementType.label // "Unknown"')

  local header="🎯 *New Bugcrowd Program*"
  if [[ "$engagement_type" == *"Vulnerability Disclosure"* ]]; then
    header="🔔 *New Bugcrowd VDP (No Bounty)*"
  fi

  local msg="${header}
*${name}*
Type: ${engagement_type}
Reward range: ${reward_summary}
Industry: ${industry}
Access: ${access_status} | Service level: ${service_level}"

  if [[ -n "$tagline" ]]; then
    msg="${msg}

${tagline}"
  fi

  msg="${msg}

${full_url}"

  echo "$msg"
}

# Fires once per day: on the first run at/after today's HEARTBEAT_HOUR:00 in HEARTBEAT_TZ.
# New-program alert as a Discord embed (built entirely by jq from the listing record)
build_discord_payload() {
  echo "$1" | jq --arg u "$DISCORD_USERNAME" '
    def v: if . == null or . == "" then "Unknown" else tostring end;
    (.productEngagementType.label | v) as $type
    | ($type | test("Vulnerability Disclosure")) as $vdp
    | {username: $u, allowed_mentions: {parse: []},
       embeds: [({
         title: ((if $vdp then "🔔 " else "🎯 " end) + (.name | v))[0:256],
         url: ("https://bugcrowd.com" + .briefUrl),
         color: (if $vdp then 9807270 else 3066993 end),
         fields: [
           {name: "Type", value: $type, inline: true},
           {name: "Reward range", value: (.rewardSummary.summary | v), inline: true},
           {name: "Industry", value: (.industryName | v), inline: true},
           {name: "Access", value: (.accessStatus | v), inline: true},
           {name: "Service level", value: (.serviceLevel | v), inline: true}
         ],
         footer: {text: (if $vdp then "New Bugcrowd VDP (no bounty)" else "New Bugcrowd program" end)},
         timestamp: (now | todate)
       } + (if (.tagline // "") != "" then {description: (.tagline[0:300])} else {} end))]}'
}

send_heartbeat_if_due() {
  local current_count="$1"
  local new_count="$2"
  local now last_heartbeat slot

  now=$(date -u +%s)
  slot=$(TZ="$HEARTBEAT_TZ" date -d "today $(printf '%02d' "$HEARTBEAT_HOUR"):00" +%s)
  last_heartbeat=0
  [[ -s "$HEARTBEAT_FILE" ]] && last_heartbeat=$(cat "$HEARTBEAT_FILE")

  if (( now >= slot && last_heartbeat < slot )); then
    notify_status "✅ Daily Bugcrowd check at $(TZ="$HEARTBEAT_TZ" date +'%H:%M %Z'): monitor alive, ${new_count} new program(s) this run (tracking ${current_count})" true
    echo "$now" > "$HEARTBEAT_FILE"
  fi
}

resp=$(fetch_all_engagements)
current_urls=$(echo "$resp" | jq -r '.engagements[].briefUrl' | sort -u)

if [[ -s "$STATE_FILE" ]]; then
  previous_urls=$(sort -u "$STATE_FILE")
  new_urls=$(comm -13 <(echo "$previous_urls") <(echo "$current_urls"))

  # Union, not overwrite: a program that's temporarily missing from a
  # flaky/paginated Bugcrowd response must stay "known" or it gets
  # re-alerted as "new" the moment it reappears (the flapping bug).
  all_known=$(printf '%s\n%s\n' "$previous_urls" "$current_urls" | sort -u | sed '/^$/d')

  if [[ -n "$new_urls" ]]; then
    while read -r url; do
      [[ -z "$url" ]] && continue
      record=$(echo "$resp" | jq -c --arg url "$url" '.engagements[] | select(.briefUrl == $url)')
      alert=$(build_alert_message "$record")
      send_telegram "$alert"
      if [[ -n "$DISCORD_WEBHOOK_URL" ]]; then
        discord_post "$DISCORD_WEBHOOK_URL" "$(build_discord_payload "$record")" || true
      fi
      sleep 1
    done <<< "$new_urls"
  fi

  # Daily heartbeat is sent at 12 am even if this run also sent alerts.
  total_count=$(echo "$all_known" | wc -l)
  new_count=$(echo "$new_urls" | sed '/^$/d' | wc -l)
  send_heartbeat_if_due "$total_count" "$new_count"
else
  all_known="$current_urls"
  total_count=$(echo "$current_urls" | wc -l)
  breakdown=$(echo "$resp" | jq -r '
    [.engagements[].productEngagementType.label]
    | group_by(.)
    | map("\(.[0]): \(length)")
    | join(", ")
  ')
  notify_status "✅ Bugcrowd monitor started - tracking ${total_count} programs

Breakdown by type: ${breakdown}"
  date -u +%s > "$HEARTBEAT_FILE"  # next heartbeat at the coming midnight
fi

echo "$all_known" > "$STATE_FILE"
