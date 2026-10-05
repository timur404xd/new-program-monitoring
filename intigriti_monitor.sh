#!/bin/bash
# intigriti_monitor.sh
# Monitors Intigriti for new bug bounty programs and sends enriched Telegram alerts.
# Designed to run in GitHub Actions — state file lives in the repo checkout
# so it can be committed back between runs (runners are stateless).
# Sends a silent "no new programs" heartbeat at most once every 6 hours.

set -euo pipefail

INTIGRITI_TOKEN="${INTIGRITI_API_TOKEN:?Set INTIGRITI_API_TOKEN env var}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?Set TELEGRAM_BOT_TOKEN env var}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:?Set TELEGRAM_CHAT_ID env var}"

# Relative to repo root — committed back by the workflow after each run.
STATE_DIR="state"
STATE_FILE="${STATE_DIR}/known_programs.json"
HEARTBEAT_FILE="${STATE_DIR}/intigriti_last_heartbeat"
HEARTBEAT_INTERVAL_SECS=$((6 * 3600))
API_BASE="https://api.intigriti.com/external/researcher/v1"

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

api_get() {
  curl -s -H "Authorization: Bearer $INTIGRITI_TOKEN" "$1"
}

fetch_all_programs() {
  local all_records="[]"
  local offset=0
  local limit=100
  local count

  while true; do
    page=$(api_get "${API_BASE}/programs?limit=${limit}&offset=${offset}")

    if ! echo "$page" | jq -e '.records' > /dev/null 2>&1; then
      echo "ERROR: unexpected API response: $page" >&2
      exit 1
    fi

    records=$(echo "$page" | jq '.records')
    count=$(echo "$records" | jq 'length')
    all_records=$(jq -s 'add' <(echo "$all_records") <(echo "$records"))
    offset=$((offset + limit))

    [[ "$count" -lt "$limit" ]] && break
  done

  echo "{\"records\": $all_records}"
}

build_alert_message() {
  local list_record="$1"
  local id name link ptype industry minbounty maxbounty currency
  local detail confidentiality asset_count asset_types safe_harbour automated_tooling vdp_or_paid

  id=$(echo "$list_record" | jq -r '.id')
  name=$(echo "$list_record" | jq -r '.name')
  link=$(echo "$list_record" | jq -r '.webLinks.detail')
  ptype=$(echo "$list_record" | jq -r '.type.value')
  industry=$(echo "$list_record" | jq -r '.industry')
  minbounty=$(echo "$list_record" | jq -r '.minBounty.value')
  maxbounty=$(echo "$list_record" | jq -r '.maxBounty.value')
  currency=$(echo "$list_record" | jq -r '.maxBounty.currency')

  detail=$(api_get "${API_BASE}/programs/${id}")

  confidentiality=$(echo "$detail" | jq -r '.confidentialityLevel.value // "Unknown"')
  asset_count=$(echo "$detail" | jq -r '.domains.content | length // 0')
  asset_types=$(echo "$detail" | jq -r '[.domains.content[].type.value] | unique | join(", ") // "Unknown"')
  safe_harbour=$(echo "$detail" | jq -r '.rulesOfEngagement.content.safeHarbour // false')
  automated_tooling=$(echo "$detail" | jq -r '.rulesOfEngagement.content.testingRequirements.automatedTooling // "Unknown"')

  if [[ "$maxbounty" == "0" || "$maxbounty" == "0.0" ]]; then
    vdp_or_paid="VDP (no bounty)"
  else
    vdp_or_paid="Paid bounty"
  fi

  local msg="🎯 *New Intigriti Program*
*${name}*
Type: ${ptype} (${vdp_or_paid})
Industry: ${industry}
Reward range: ${minbounty} - ${maxbounty} ${currency}
Confidentiality: ${confidentiality}
Assets: ${asset_count} (${asset_types})
Safe harbour: ${safe_harbour} | Automated tooling flag: ${automated_tooling}

${link}"

  echo "$msg"
}

send_heartbeat_if_due() {
  local current_count="$1"
  local now last_heartbeat

  now=$(date -u +%s)
  last_heartbeat=0
  [[ -f "$HEARTBEAT_FILE" ]] && last_heartbeat=$(cat "$HEARTBEAT_FILE")

  if (( now - last_heartbeat >= HEARTBEAT_INTERVAL_SECS )); then
    send_telegram "✅ Intigriti check OK at $(date -u +'%H:%M UTC'): no new programs (tracking ${current_count})" true
    echo "$now" > "$HEARTBEAT_FILE"
  fi
}

resp=$(fetch_all_programs)
current_ids=$(echo "$resp" | jq -r '.records[].id' | sort)

if [[ -f "$STATE_FILE" ]]; then
  previous_ids=$(cat "$STATE_FILE")
  new_ids=$(comm -13 <(echo "$previous_ids") <(echo "$current_ids"))

  # Union, not overwrite: a program temporarily missing from a flaky
  # API response must stay "known" or it gets re-alerted on return.
  all_known=$(printf '%s\n%s\n' "$previous_ids" "$current_ids" | sort -u | sed '/^$/d')

  if [[ -n "$new_ids" ]]; then
    while read -r id; do
      [[ -z "$id" ]] && continue
      list_record=$(echo "$resp" | jq -c --arg id "$id" '.records[] | select(.id == $id)')
      alert=$(build_alert_message "$list_record")
      send_telegram "$alert"
      sleep 1
    done <<< "$new_ids"
    # No heartbeat on a run that already sent real alerts.
  else
    total_count=$(echo "$all_known" | wc -l)
    send_heartbeat_if_due "$total_count"
  fi
else
  all_known="$current_ids"
  send_telegram "✅ Intigriti monitor started — tracking $(echo "$current_ids" | wc -l) programs."
  date -u +%s > "$HEARTBEAT_FILE"
fi

echo "$all_known" > "$STATE_FILE"
