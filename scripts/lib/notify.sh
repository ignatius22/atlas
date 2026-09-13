#!/usr/bin/env bash
# ==============================================================================
# Atlas Production Template - Unified Notification & Alerting Library (V1.1)
# ==============================================================================
# Dispatches alerts to webhooks (Discord, Slack, Telegram, Generic Webhook)
# Ensures zero credentials, tokens, webhook URLs, or sensitive payload data are leaked.
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Helper: Redact sensitive patterns from messages
# ------------------------------------------------------------------------------
sanitize_notification_text() {
  local input="$1"
  # Redact passwords, secrets, keys, tokens, and webhook URLs
  echo "${input}" | sed -E \
    -e 's/(password|passwd|secret|key|token|authorization)[ =:]+[^ &]*/\1=[REDACTED]/gi' \
    -e 's/(AGE-SECRET-KEY-[A-Za-z0-9]+)/[REDACTED_AGE_KEY]/g' \
    -e 's/(https?:\/\/(discord\.com|hooks\.slack\.com)\/api\/webhooks\/)[^ "]+/\1[REDACTED_WEBHOOK]/gi' \
    -e 's/(https?:\/\/[^:]+:)[^@]+(@)/\1[REDACTED_AUTH]\2/g'
}

# ------------------------------------------------------------------------------
# Helper: Build JSON payload portably (using jq if available, otherwise python3)
# ------------------------------------------------------------------------------
build_json_payload() {
  local template_type="$1" # discord, slack, telegram, generic
  local status="$2"
  local title="$3"
  local details="$4"
  local host="$5"
  local time="$6"
  local color="$7"
  local emoji="$8"

  if command -v jq >/dev/null 2>&1; then
    case "${template_type}" in
      discord)
        jq -n \
          --arg title "${emoji} [${status}] ${title}" \
          --arg desc "${details}" \
          --arg host "${host}" \
          --arg time "${time}" \
          --argjson color "${color}" \
          '{
            embeds: [{
              title: $title,
              description: $desc,
              color: $color,
              fields: [
                { name: "Host", value: $host, inline: true },
                { name: "Timestamp (UTC)", value: $time, inline: true }
              ]
            }]
          }'
        ;;
      slack)
        jq -n \
          --arg text "${emoji} *[${status}] ${title}*\n*Host:* \`${host}\` | *Time:* \`${time}\`\n${details}" \
          '{ text: $text }'
        ;;
      generic)
        jq -n \
          --arg status "${status}" \
          --arg title "${title}" \
          --arg details "${details}" \
          --arg host "${host}" \
          --arg timestamp "${time}" \
          '{ status: $status, title: $title, details: $details, host: $host, timestamp: $timestamp }'
        ;;
    esac
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import sys, json
t, status, title, details, host, timestamp, color, emoji = sys.argv[1:9]
if t == "discord":
    payload = {
        "embeds": [{
            "title": f"{emoji} [{status}] {title}",
            "description": details,
            "color": int(color),
            "fields": [
                {"name": "Host", "value": host, "inline": True},
                {"name": "Timestamp (UTC)", "value": timestamp, "inline": True}
            ]
        }]
    }
elif t == "slack":
    payload = {"text": f"{emoji} *[{status}] {title}*\n*Host:* `{host}` | *Time:* `{timestamp}`\n{details}"}
else:
    payload = {"status": status, "title": title, "details": details, "host": host, "timestamp": timestamp}
print(json.dumps(payload))
' "${template_type}" "${status}" "${title}" "${details}" "${host}" "${time}" "${color}" "${emoji}"
  else
    # Minimal fallback
    printf '{"text": "[%s] %s: %s"}' "${status}" "${title}" "${details}"
  fi
}

# ------------------------------------------------------------------------------
# Core Dispatcher: send_atlas_notification
# Arguments:
#   1. Status: "SUCCESS", "WARNING", "FAILURE", "CRITICAL"
#   2. Event Title: e.g. "Database Backup Failed"
#   3. Details: Detailed markdown or plain-text description
# ------------------------------------------------------------------------------
send_atlas_notification() {
  local status="${1:-INFO}"
  local title="${2:-Atlas Notification}"
  local details="${3:-No details provided.}"

  # Keep success notifications disabled by default
  if [ "${status}" = "SUCCESS" ] && [ "${ATLAS_NOTIFY_SUCCESS:-false}" != "true" ]; then
    return 0
  fi

  local clean_title
  clean_title="$(sanitize_notification_text "${title}")"
  local clean_details
  clean_details="$(sanitize_notification_text "${details}")"
  local host_name
  host_name="$(hostname -f 2>/dev/null || hostname)"
  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  # Determine color / emoji based on status
  local color_hex="3447003" # Blue/Info default
  local emoji="ℹ️"
  case "${status}" in
    SUCCESS)  color_hex="3066993"; emoji="✅" ;; # Green
    WARNING)  color_hex="16776960"; emoji="⚠️" ;; # Yellow
    FAILURE)  color_hex="15158332"; emoji="❌" ;; # Red
    CRITICAL) color_hex="10038562"; emoji="🚨" ;; # Dark Red
  esac

  # 1. Discord Webhook (URLs never echoed to logs/stdout)
  if [ -n "${ATLAS_DISCORD_WEBHOOK:-}" ]; then
    local discord_payload
    discord_payload="$(build_json_payload "discord" "${status}" "${clean_title}" "${clean_details}" "${host_name}" "${timestamp}" "${color_hex}" "${emoji}")"

    curl -sS -m 10 -H "Content-Type: application/json" \
      -d "${discord_payload}" "${ATLAS_DISCORD_WEBHOOK}" >/dev/null 2>&1 || true
  fi

  # 2. Slack Webhook (URLs never echoed to logs/stdout)
  if [ -n "${ATLAS_SLACK_WEBHOOK:-}" ]; then
    local slack_payload
    slack_payload="$(build_json_payload "slack" "${status}" "${clean_title}" "${clean_details}" "${host_name}" "${timestamp}" "${color_hex}" "${emoji}")"

    curl -sS -m 10 -H "Content-Type: application/json" \
      -d "${slack_payload}" "${ATLAS_SLACK_WEBHOOK}" >/dev/null 2>&1 || true
  fi

  # 3. Telegram Bot
  if [ -n "${ATLAS_TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${ATLAS_TELEGRAM_CHAT_ID:-}" ]; then
    local tg_text="${emoji} *[${status}] ${clean_title}*%0A*Host:* \`${host_name}\`%0A*Time:* \`${timestamp}\`%0A%0A${clean_details}"
    curl -sS -m 10 -X POST \
      "https://api.telegram.org/bot${ATLAS_TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${ATLAS_TELEGRAM_CHAT_ID}&parse_mode=Markdown&text=${tg_text}" >/dev/null 2>&1 || true
  fi

  # 4. Generic JSON Webhook
  if [ -n "${ATLAS_GENERIC_WEBHOOK:-}" ]; then
    local generic_payload
    generic_payload="$(build_json_payload "generic" "${status}" "${clean_title}" "${clean_details}" "${host_name}" "${timestamp}" "${color_hex}" "${emoji}")"

    curl -sS -m 10 -H "Content-Type: application/json" \
      -d "${generic_payload}" "${ATLAS_GENERIC_WEBHOOK}" >/dev/null 2>&1 || true
  fi
}

# ------------------------------------------------------------------------------
# Repeated Scheduler Failure Tracker
# ------------------------------------------------------------------------------
record_scheduler_run_result() {
  local result="${1:-success}" # "success" or "failure"
  local state_dir="${ATLAS_SCHEDULER_STATE_DIR:-/tmp/atlas_scheduler}"
  local count_file="${state_dir}/consecutive_failures"
  local threshold="${ATLAS_SCHEDULER_ALERT_THRESHOLD:-2}"

  mkdir -p "${state_dir}" 2>/dev/null || true

  if [ "${result}" = "success" ]; then
    rm -f "${count_file}" 2>/dev/null || true
    return 0
  fi

  # Increment failure count
  local count=1
  if [ -f "${count_file}" ]; then
    local prev
    prev="$(cat "${count_file}" 2>/dev/null || echo "0")"
    if [[ "${prev}" =~ ^[0-9]+$ ]]; then
      count=$((prev + 1))
    fi
  fi
  echo "${count}" > "${count_file}" 2>/dev/null || true

  if [ "${count}" -ge "${threshold}" ]; then
    send_atlas_notification "CRITICAL" "Repeated Backup Scheduler Failure" \
      "The automated backup scheduler has failed ${count} consecutive times on host \`$(hostname)\`.\nImmediate operator attention is required.\nInspect journal logs: \`journalctl -u atlas-backup.service -n 100 --no-pager\`" || true
  fi
}
