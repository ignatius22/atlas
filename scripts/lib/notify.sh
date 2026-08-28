#!/usr/bin/env bash
# ==============================================================================
# Atlas Production Template - Unified Notification & Alerting Library (V1.1)
# ==============================================================================
# Dispatches alerts to webhooks (Discord, Slack, Telegram, Generic Webhook)
# Ensures zero credentials, tokens, or sensitive payload data are leaked.
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Helper: Redact sensitive patterns from messages
# ------------------------------------------------------------------------------
sanitize_notification_text() {
  local input="$1"
  # Redact passwords, secrets, keys, and tokens
  echo "${input}" | sed -E \
    -e 's/(password|passwd|secret|key|token|authorization)[ =:]+[^ &]*/\1=[REDACTED]/gi' \
    -e 's/(AGE-SECRET-KEY-[A-Za-z0-9]+)/[REDACTED_AGE_KEY]/g' \
    -e 's/(https?:\/\/[^:]+:)[^@]+(@)/\1[REDACTED_AUTH]\2/g'
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

  # 1. Discord Webhook
  if [ -n "${ATLAS_DISCORD_WEBHOOK:-}" ]; then
    local discord_payload
    discord_payload="$(jq -n \
      --arg title "${emoji} [${status}] ${clean_title}" \
      --arg desc "${clean_details}" \
      --arg host "${host_name}" \
      --arg time "${timestamp}" \
      --argjson color "${color_hex}" \
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
      }')"
      
    curl -sS -m 10 -H "Content-Type: application/json" \
      -d "${discord_payload}" "${ATLAS_DISCORD_WEBHOOK}" >/dev/null 2>&1 || true
  fi

  # 2. Slack Webhook
  if [ -n "${ATLAS_SLACK_WEBHOOK:-}" ]; then
    local slack_payload
    slack_payload="$(jq -n \
      --arg text "${emoji} *[${status}] ${clean_title}*\n*Host:* \`${host_name}\` | *Time:* \`${timestamp}\`\n${clean_details}" \
      '{ text: $text }')"
      
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
    generic_payload="$(jq -n \
      --arg status "${status}" \
      --arg title "${clean_title}" \
      --arg details "${clean_details}" \
      --arg host "${host_name}" \
      --arg timestamp "${timestamp}" \
      '{
        status: $status,
        title: $title,
        details: $details,
        host: $host,
        timestamp: $timestamp
      }')"
      
    curl -sS -m 10 -H "Content-Type: application/json" \
      -d "${generic_payload}" "${ATLAS_GENERIC_WEBHOOK}" >/dev/null 2>&1 || true
  fi
}
