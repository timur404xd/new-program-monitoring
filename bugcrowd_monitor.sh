#!/bin/bash
# bugcrowd_monitor.sh
# Monitors Bugcrowd's public program directory (bug_bounty + vdp categories)
# for new programs and sends Telegram alerts. No auth required.
# Sends a silent "no new programs" heartbeat at most once every 6 hours.

set -euo pipefail

export LC_ALL=C

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?Set TELEGRAM_BOT_TOKEN env var}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:?Set TELEGRAM_CHAT_ID env var}"

STATE_DIR="state"
STATE_FILE="${STATE_DIR}/known_bugcrowd_programs.json"
HEARTBEAT_FILE="${STATE_DIR}/bugcrowd_last_heartbeat"
HEARTBEAT_INTERVAL_SECS=$((6 * 3600))
BASE_URL="https://bugcrowd.com/engagements-us.json"
CATEGORIES=("bug_bounty" "vdp")

mkdir -p "$STATE_DIR"

# Second argument "true" sends the message silently (no sound/vibration)
send_telegram() {
  local message="$1"
  local silent="${2:-false}"
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d parse_mode="Markdown" \
    -d disable_notification="${silent}" \
    --data-urlencode text="${message}" > /dev/null
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

send_heartbeat_if_due() {
  local current_count="$1"
  local now last_heartbeat

  now=$(date -u +%s)
  last_heartbeat=0
  [[ -f "$HEARTBEAT_FILE" ]] && last_heartbeat=$(cat "$HEARTBEAT_FILE")

  if (( now - last_heartbeat >= HEARTBEAT_INTERVAL_SECS )); then
    send_telegram "✅ Bugcrowd check OK at $(date -u +'%H:%M UTC'): no new programs (tracking ${current_count})" true
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
      sleep 1
    done <<< "$new_urls"
    # No heartbeat on a run that already sent real alerts.
  else
    total_count=$(echo "$all_known" | wc -l)
    send_heartbeat_if_due "$total_count"
  fi
else
  all_known="$current_urls"
  total_count=$(echo "$current_urls" | wc -l)
  breakdown=$(echo "$resp" | jq -r '
    [.engagements[].productEngagementType.label]
    | group_by(.)
    | map("\(.[0]): \(length)")
    | join(", ")
  ')
  send_telegram "✅ Bugcrowd monitor started - tracking ${total_count} programs

Breakdown by type: ${breakdown}"
  date -u +%s > "$HEARTBEAT_FILE"
fi

echo "$all_known" > "$STATE_FILE"
