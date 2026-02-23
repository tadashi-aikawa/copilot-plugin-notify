#!/usr/bin/env bash
set -euo pipefail

INPUT="$(cat)"
DEBUG_MODE="${COPILOT_NOTIFY_DEBUG:-0}"
DEBUG_PATH="${COPILOT_NOTIFY_DEBUG_PATH:-/tmp/copilot-notify.jsonl}"

if [ "$DEBUG_MODE" = "1" ]; then
  printf '%s\n' "$INPUT" >>"$DEBUG_PATH"
fi

STOP_REASON="$(
  echo "$INPUT" | jq -r '
    .stopReason
    // empty
  '
)"

TRANSCRIPT_PATH="$(
  echo "$INPUT" | jq -r '
    .transcriptPath
    // empty
  '
)"

TOOL_NAME="$(
  echo "$INPUT" | jq -r '
    .toolName
    // empty
  '
)"

QUESTION="$(
  echo "$INPUT" | jq -r '
    .toolArgs as $toolArgs
    | if ($toolArgs | type) == "object" then
        ($toolArgs.question // "")
      elif ($toolArgs | type) == "string" then
        (try (($toolArgs | fromjson).question // "") catch "")
      else
        ""
      end
  '
)"

if [ -n "$QUESTION" ]; then
  QUESTION="$(
    printf '%s' "$QUESTION" |
      tr '\r\n' '  ' |
      sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
  )"
fi

SUMMARY="$(
  echo "$INPUT" | jq -r '
    .toolArgs as $toolArgs
    | if ($toolArgs | type) == "object" then
        ($toolArgs.summary // "")
      elif ($toolArgs | type) == "string" then
        (try (($toolArgs | fromjson).summary // "") catch "")
      else
        ""
      end
  '
)"

if [ -n "$SUMMARY" ]; then
  SUMMARY="$(
    printf '%s' "$SUMMARY" |
      tr '\r\n' '  ' |
      sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
  )"
fi

TOOL_PATH="$(
  echo "$INPUT" | jq -r '
    .toolArgs as $toolArgs
    | if ($toolArgs | type) == "object" then
        ($toolArgs.path // "")
      elif ($toolArgs | type) == "string" then
        (try (($toolArgs | fromjson).path // "") catch "")
      else
        ""
      end
  '
)"

INPUT_TOOL_REQUESTS_COUNT="$(
  echo "$INPUT" | jq -r '
    (.data.toolRequests // [])
    | if type == "array" then length else 1 end
  '
)"

INPUT_TIMESTAMP_MS="$(
  echo "$INPUT" | jq -r '
    .timestamp as $ts
    | if ($ts | type) == "number" then
        ($ts | floor)
      elif ($ts | type) == "string" then
        (try (($ts | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) * 1000 | floor) catch 0)
      else
        0
      end
  '
)"

AGENTSTOP_POLL_ATTEMPTS="${COPILOT_NOTIFY_AGENTSTOP_POLL_ATTEMPTS:-10}"
AGENTSTOP_POLL_INTERVAL_SEC="${COPILOT_NOTIFY_AGENTSTOP_POLL_INTERVAL_SEC:-0.05}"
AGENTSTOP_ACCEPTABLE_AGE_MS="${COPILOT_NOTIFY_AGENTSTOP_ACCEPTABLE_AGE_MS:-3000}"

BODY=""

if [ "$DEBUG_MODE" = "1" ]; then
  printf 'TOOL_NAME: %s\n' "$TOOL_NAME" >>"$DEBUG_PATH"
fi

if [[ "$TOOL_NAME" = "ask_user" ]]; then
  BODY="$QUESTION"
elif [[ "$TOOL_NAME" = "exit_plan_mode" ]]; then
  BODY="$SUMMARY"
elif [[ "$TOOL_NAME" = "bash" ]]; then
  BODY="${TOOL_NAME}"
elif [[ "$TOOL_NAME" = "edit" ]]; then
  if [ -n "$TOOL_PATH" ]; then
    BODY="edit: ${TOOL_PATH}"
  else
    BODY="edit"
  fi
elif [[ "$TOOL_NAME" = "report_intent" ]]; then
  # DO NOTHING
  echo ""
elif [ "$STOP_REASON" = "end_turn" ] || [ -n "$TRANSCRIPT_PATH" ]; then
  if [ "$DEBUG_MODE" = "1" ]; then
    printf '%s\n' "$INPUT" >>/tmp/copilot-notify-agent-stop.jsonl
  fi

  if [ "$INPUT_TOOL_REQUESTS_COUNT" -eq 0 ] && [ -n "$TRANSCRIPT_PATH" ]; then
    MIN_ACCEPT_TS_MS=0
    if [ "$INPUT_TIMESTAMP_MS" -gt 0 ]; then
      MIN_ACCEPT_TS_MS=$((INPUT_TIMESTAMP_MS - AGENTSTOP_ACCEPTABLE_AGE_MS))
      if [ "$MIN_ACCEPT_TS_MS" -lt 0 ]; then
        MIN_ACCEPT_TS_MS=0
      fi
    fi

    ATTEMPT=0
    while [ "$ATTEMPT" -lt "$AGENTSTOP_POLL_ATTEMPTS" ]; do
      BODY="$(
        jq -r --argjson min_ts "$MIN_ACCEPT_TS_MS" '
          select(.type == "assistant.message")
          | select((.data.toolRequests // []) | length == 0)
          | {
              ts_ms: (try ((.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) * 1000 | floor) catch 0),
              content: (.data.content // "")
            }
          | select((.content | length) > 0)
          | select(.ts_ms >= $min_ts)
          | .content
        ' "$TRANSCRIPT_PATH" |
          awk 'length > 0 { line = $0 } END { print line }'
      )"

      if [ -n "$BODY" ]; then
        break
      fi

      ATTEMPT=$((ATTEMPT + 1))
      if [ "$ATTEMPT" -lt "$AGENTSTOP_POLL_ATTEMPTS" ]; then
        sleep "$AGENTSTOP_POLL_INTERVAL_SEC"
      fi
    done
  fi
fi

notify() {
  local title="$1"
  local body="$2"
  if [ "$DEBUG_MODE" = "1" ]; then
    printf 'title: %s | body: %s' "$title" "$body" >>"$DEBUG_PATH"
  fi
  if [ "${COPILOT_NOTIFY_FORCE_STDOUT:-0}" = "1" ]; then
    printf '\e]777;notify;%s;%s\a' "$title" "$body"
  else
    printf '\e]777;notify;%s;%s\a' "$title" "$body" >/dev/tty
  fi
}

if [[ ! -z "$BODY" ]]; then
  notify "Copilot" "$BODY"
fi

if [ "$DEBUG_MODE" = "1" ]; then
  printf "\n\n" >>"$DEBUG_PATH"
fi
