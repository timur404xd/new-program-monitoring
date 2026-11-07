#!/bin/bash
# intigriti_monitor.sh
# Monitors Intigriti for new bug bounty programs and sends enriched alerts to Discord
# and/or Telegram.
# Designed to run in GitHub Actions — state file lives in the repo checkout
# so it can be committed back between runs (runners are stateless).
# Sends a silent daily heartbeat on the first run at/after HEARTBEAT_HOUR:00
# in HEARTBEAT_TZ (default 00:00 Africa/Cairo).

set -euo pipefail

INTIGRITI_TOKEN="${INTIGRITI_API_TOKEN:?Set INTIGRITI_API_TOKEN env var}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
# Discord: new-program alerts go to DISCORD_WEBHOOK_URL; startup notice and heartbeat go to
# DISCORD_HEARTBEAT_WEBHOOK_URL (falls back to DISCORD_WEBHOOK_URL when not set).
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
DISCORD_HEARTBEAT_WEBHOOK_URL="${DISCORD_HEARTBEAT_WEBHOOK_URL:-$DISCORD_WEBHOOK_URL}"
DISCORD_USERNAME="${DISCORD_USERNAME:-Intigriti Programs}"
if [[ -z "$DISCORD_WEBHOOK_URL" && ( -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ) ]]; then
  echo "ERROR: set DISCORD_WEBHOOK_URL and/or TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID" >&2
  exit 1
fi

# Relative to repo root — committed back by the workflow after each run.
STATE_DIR="state"
STATE_FILE="${STATE_DIR}/known_programs.json"
HEARTBEAT_FILE="${STATE_DIR}/intigriti_last_heartbeat"
HEARTBEAT_TZ="${HEARTBEAT_TZ:-Africa/Cairo}"
HEARTBEAT_HOUR="${HEARTBEAT_HOUR:-0}"  # 0 = 12 am
API_BASE="https://api.intigriti.com/external/researcher/v1"

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

# $2 is the program detail JSON (fetched once by the caller, shared with the Discord embed)
build_alert_message() {
  local list_record="$1"
  local detail="$2"
  local id name link ptype industry minbounty maxbounty currency
  local confidentiality asset_count asset_types safe_harbour automated_tooling vdp_or_paid

  id=$(echo "$list_record" | jq -r '.id')
  name=$(echo "$list_record" | jq -r '.name')
  link=$(echo "$list_record" | jq -r '.webLinks.detail')
  ptype=$(echo "$list_record" | jq -r '.type.value')
  industry=$(echo "$list_record" | jq -r '.industry')
  minbounty=$(echo "$list_record" | jq -r '.minBounty.value')
  maxbounty=$(echo "$list_record" | jq -r '.maxBounty.value')
  currency=$(echo "$list_record" | jq -r '.maxBounty.currency')

  confidentiality=$(echo "$detail" | jq -r '.confidentialityLevel.value // "Unknown"')
  asset_count=$(echo "$detail" | jq -r '.domains.content | length // 0')
  asset_types=$(echo "$detail" | jq -r '[.domains.content[]?.type.value] | unique | join(", ")')
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

# Fires once per day: on the first run at/after today's HEARTBEAT_HOUR:00 in HEARTBEAT_TZ.
# New-program alert as a Discord embed (built entirely by jq from the list record + detail)
build_discord_payload() {
  jq -n --argjson r "$1" --argjson d "$2" --arg u "$DISCORD_USERNAME" '
    def v: if . == null or . == "" then "Unknown" else tostring end;
    (($r.maxBounty.value // 0) == 0) as $vdp
    | ([$d.domains.content[]?.type.value] | unique | join(", ")) as $types
    | ($d.rulesOfEngagement.content.testingRequirements.automatedTooling
       | if type == "object" then .value else . end) as $tooling
    | {username: $u, allowed_mentions: {parse: []},
       embeds: [({
         title: ("🎯 " + ($r.name | v))[0:256],
         color: (if $vdp then 9807270 else 3066993 end),
         fields: [
           {name: "Type", value: (($r.type.value | v) + (if $vdp then " (VDP, no bounty)" else " (paid bounty)" end)), inline: true},
           {name: "Reward range", value: "\($r.minBounty.value // "?") - \($r.maxBounty.value // "?") \($r.maxBounty.currency // "")", inline: true},
           {name: "Industry", value: ($r.industry | v), inline: true},
           {name: "Confidentiality", value: ($d.confidentialityLevel.value | v), inline: true},
           {name: "Assets", value: ("\([$d.domains.content[]?] | length)" + (if $types != "" then " (\($types))" else "" end)), inline: true},
           {name: "Safe harbour", value: ($d.rulesOfEngagement.content.safeHarbour | v), inline: true},
           {name: "Automated tooling", value: ($tooling | v), inline: true}
         ],
         footer: {text: "New Intigriti program"},
         timestamp: (now | todate)
       } + (if ($r.webLinks.detail // "") | startswith("http") then {url: $r.webLinks.detail} else {} end))]}'
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
    notify_status "✅ Daily Intigriti check at $(TZ="$HEARTBEAT_TZ" date +'%H:%M %Z'): monitor alive, ${new_count} new program(s) this run (tracking ${current_count})" true
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
      detail=$(api_get "${API_BASE}/programs/$(echo "$list_record" | jq -r '.id')")
      # a failed/odd detail response must not break the alert: fall back to the list data only
      echo "$detail" | jq -e 'type == "object"' > /dev/null 2>&1 || detail='{}'
      alert=$(build_alert_message "$list_record" "$detail")
      send_telegram "$alert"
      if [[ -n "$DISCORD_WEBHOOK_URL" ]]; then
        discord_post "$DISCORD_WEBHOOK_URL" "$(build_discord_payload "$list_record" "$detail")" || true
      fi
      sleep 1
    done <<< "$new_ids"
  fi

  # Daily heartbeat is sent at 12 am even if this run also sent alerts.
  total_count=$(echo "$all_known" | wc -l)
  new_count=$(echo "$new_ids" | sed '/^$/d' | wc -l)
  send_heartbeat_if_due "$total_count" "$new_count"
else
  all_known="$current_ids"
  notify_status "✅ Intigriti monitor started — tracking $(echo "$current_ids" | wc -l) programs."
  date -u +%s > "$HEARTBEAT_FILE"  # next heartbeat at the coming midnight
fi

echo "$all_known" > "$STATE_FILE"
