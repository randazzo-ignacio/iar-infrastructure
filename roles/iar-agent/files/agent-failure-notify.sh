#!/usr/bin/env bash
# agent-failure-notify.sh -- OnFailure hook for i.ar agent systemd units.
#
# Triggered by OnFailure=agent-failure@%n.service from agent units
# (aria-cycle.service, iar-<agent>.service, ...). %i (the instance
# name) is the failed unit name.
#
# Sends a Telegram notification with the failure reason (last journal
# lines -- the tripwire prints its blocking file list there).
#
# Design decisions (2026-08-31, after the 1h50m tripwire deadlock):
#   - Rate-limited: one message per unit per 30 min. A persistent
#     failure loop (e.g. root-owned files blocking every cycle) must
#     not spam the human into muting the channel.
#   - Rate-limit state is written ONLY after a confirmed Telegram
#     send (API "ok":true). A failure handler that fails silently is
#     the exact class this hook exists to fix.
#   - All attempts logged to syslog (journalctl -t agent-failure).
#
# Credentials: sourced from the i.ar repo's utils/telegram.sh
# (deployed by Ansible from vault, git-ignored).

set -u

UNIT="${1:-unknown-unit}"
HOST="$(hostname -s)"
RATE_LIMIT=1800  # seconds between notifications per unit
STATE_DIR="/var/tmp/agent-failure-notify"
TELEGRAM_SH="/var/home/nacho/repos/i.ar/utils/telegram.sh"

log() { logger -t agent-failure "$1"; }

# --- Gather failure details from systemd ---
RESULT="$(systemctl show "$UNIT" -p Result --value 2>/dev/null)"
STATUS="$(systemctl show "$UNIT" -p ExecMainStatus --value 2>/dev/null)"
SINCE="$(systemctl show "$UNIT" -p ExecMainExitTimestamp --value 2>/dev/null)"

# Last journal lines of the failed unit (tripwire reason lives here)
JOURNAL="$(journalctl -u "$UNIT" -n 4 --no-pager 2>/dev/null | sed 's/^/  /' | tail -4)"

# --- Rate limit per unit ---
mkdir -p "$STATE_DIR"
STATE_FILE="${STATE_DIR}/${UNIT}.last"
NOW=$(date +%s)
LAST=0
[[ -f "$STATE_FILE" ]] && LAST=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
if (( NOW - LAST < RATE_LIMIT )); then
    log "suppressed notification for ${UNIT} (last sent $((NOW - LAST))s ago)"
    exit 0
fi

# --- Telegram credentials ---
if [[ -f "$TELEGRAM_SH" ]]; then
    # shellcheck disable=SC1090
    source "$TELEGRAM_SH"
else
    log "ERROR: telegram credentials not found at ${TELEGRAM_SH}"
    exit 1
fi

if [[ -z "${AGENT_TELEGRAM_BOT_TOKEN:-}" || -z "${AGENT_TELEGRAM_CHAT_ID:-}" ]]; then
    log "ERROR: telegram credentials empty after sourcing ${TELEGRAM_SH}"
    exit 1
fi

# --- Compose message ---
MSG="[iar-failure] ${UNIT} FAILED on ${HOST}
result: ${RESULT:-unknown} (exit ${STATUS:-?}) at ${SINCE:-unknown}
journal tail:
${JOURNAL:-  (no journal lines)}"

# --- Send ---
RESPONSE="$(curl -s -m 15 --connect-timeout 5 -X POST \
    "https://api.telegram.org/bot${AGENT_TELEGRAM_BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg chat_id "$AGENT_TELEGRAM_CHAT_ID" \
               --arg text "$MSG" \
               '{chat_id: $chat_id, text: $text}')" 2>/dev/null)"
CURL_RC=$?

if [[ $CURL_RC -ne 0 ]]; then
    log "ERROR: curl failed (rc=${CURL_RC}) for ${UNIT} -- will retry on next failure"
    exit 1
fi

if echo "$RESPONSE" | jq -e '.ok == true' > /dev/null 2>&1; then
    echo "$NOW" > "$STATE_FILE"
    log "notification sent for ${UNIT} (result=${RESULT} exit=${STATUS})"
    exit 0
else
    log "ERROR: telegram API rejected send for ${UNIT}: ${RESPONSE:0:200}"
    exit 1
fi