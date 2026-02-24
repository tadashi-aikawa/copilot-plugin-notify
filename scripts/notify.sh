#!/usr/bin/env bash
set -euo pipefail

INPUT="$(cat)"
DEBUG_MODE="${COPILOT_NOTIFY_DEBUG:-0}"
DEBUG_PATH="${COPILOT_NOTIFY_DEBUG_PATH:-/tmp/copilot-notify.jsonl}"
ALLOW_TOOL_RULES="${COPILOT_NOTIFY_ALLOW_TOOL_RULES:-}"
DENY_TOOL_RULES="${COPILOT_NOTIFY_DENY_TOOL_RULES:-}"
ALLOW_URLS="${COPILOT_NOTIFY_ALLOW_URLS:-}"
ALLOW_PATHS="${COPILOT_NOTIFY_ALLOW_PATHS:-}"

if [ "$DEBUG_MODE" = "1" ]; then
  printf '%s\n' "$INPUT" >>"$DEBUG_PATH"
fi

normalize_spaces() {
  local value="$1"
  printf '%s' "$value" |
    tr '\r\n\t' '   ' |
    sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

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

CWD_PATH="$(
  echo "$INPUT" | jq -r '
    .cwd
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
  QUESTION="$(normalize_spaces "$QUESTION")"
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
  SUMMARY="$(normalize_spaces "$SUMMARY")"
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

TOOL_COMMAND="$(
  echo "$INPUT" | jq -r '
    .toolArgs as $toolArgs
    | if ($toolArgs | type) == "object" then
        ($toolArgs.command // "")
      elif ($toolArgs | type) == "string" then
        (try (($toolArgs | fromjson).command // "") catch "")
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

starts_with_token_prefix() {
  local text="$1"
  local prefix="$2"
  if [ -z "$text" ] || [ -z "$prefix" ]; then
    return 1
  fi
  [[ "$text" = "$prefix" || "$text" = "$prefix "* ]]
}

matches_shell_rule() {
  local command="$1"
  local shell_pattern="$2"
  local normalized_pattern

  normalized_pattern="$(normalize_spaces "$shell_pattern")"
  if [[ "$normalized_pattern" = *":*" ]]; then
    normalized_pattern="${normalized_pattern%:*}"
  fi
  normalized_pattern="$(normalize_spaces "$normalized_pattern")"

  starts_with_token_prefix "$command" "$normalized_pattern"
}

matches_rule() {
  local tool_name="$1"
  local command="$2"
  local raw_rule="$3"
  local rule
  local shell_inner

  rule="$(normalize_spaces "$raw_rule")"
  if [ -z "$rule" ]; then
    return 1
  fi

  if [[ "$rule" == shell\(*\) ]]; then
    if [[ "$tool_name" != "bash" && "$tool_name" != "shell" ]]; then
      return 1
    fi
    if [ -z "$command" ]; then
      return 1
    fi
    shell_inner="${rule#shell(}"
    shell_inner="${shell_inner%)}"
    matches_shell_rule "$command" "$shell_inner"
    return $?
  fi

  [ "$rule" = "$tool_name" ]
}

matches_any_rule() {
  local tool_name="$1"
  local command="$2"
  local rules_csv="$3"
  local rule

  if [ -z "$rules_csv" ]; then
    return 1
  fi

  IFS=',' read -r -a rules <<<"$rules_csv"
  for rule in "${rules[@]}"; do
    if matches_rule "$tool_name" "$command" "$rule"; then
      return 0
    fi
  done

  return 1
}

extract_urls_from_command() {
  local command="$1"
  # Extract URL-like tokens from shell command text.
  printf '%s\n' "$command" | grep -Eo "https?://[^[:space:]\"']+" || true
}

url_to_host() {
  local url="$1"
  local host

  host="$(printf '%s' "$url" | sed -E 's~^[a-zA-Z][a-zA-Z0-9+.-]*://~~; s~/.*$~~; s~^[^@]*@~~; s~:.*$~~')"
  host="$(normalize_spaces "$host")"
  printf '%s' "$host" | tr '[:upper:]' '[:lower:]'
}

normalize_allow_url_entry() {
  local entry="$1"
  local value

  value="$(normalize_spaces "$entry")"
  if [ -z "$value" ]; then
    echo ""
    return
  fi

  if [[ "$value" == *"://"* ]]; then
    url_to_host "$value"
    return
  fi

  value="$(printf '%s' "$value" | sed -E 's~^[^@]*@~~; s~/.*$~~; s~:.*$~~')"
  printf '%s' "$value" | tr '[:upper:]' '[:lower:]'
}

trim_trailing_slashes() {
  local value="$1"
  while [ "${#value}" -gt 1 ] && [[ "$value" = */ ]]; do
    value="${value%/}"
  done
  printf '%s' "$value"
}

normalize_allow_path_entry() {
  local entry="$1"
  local value

  value="$(normalize_spaces "$entry")"
  if [ -z "$value" ]; then
    echo ""
    return
  fi

  trim_trailing_slashes "$value"
}

normalize_tool_path() {
  local path="$1"
  local normalized

  normalized="$(normalize_spaces "$path")"
  if [ -z "$normalized" ]; then
    echo ""
    return
  fi

  trim_trailing_slashes "$normalized"
}

resolve_tool_path() {
  local tool_path="$1"
  local cwd_path="$2"
  local normalized_tool_path
  local normalized_cwd_path

  normalized_tool_path="$(normalize_tool_path "$tool_path")"
  if [ -z "$normalized_tool_path" ]; then
    echo ""
    return
  fi

  if [[ "$normalized_tool_path" = /* ]]; then
    echo "$normalized_tool_path"
    return
  fi

  normalized_cwd_path="$(normalize_tool_path "$cwd_path")"
  if [ -z "$normalized_cwd_path" ]; then
    echo "$normalized_tool_path"
    return
  fi

  if [ "$normalized_tool_path" = "." ]; then
    echo "$normalized_cwd_path"
    return
  fi

  printf '%s/%s' "$normalized_cwd_path" "$normalized_tool_path"
}

path_is_under_prefix() {
  local path="$1"
  local prefix="$2"

  if [ -z "$path" ] || [ -z "$prefix" ]; then
    return 1
  fi

  if [ "$prefix" = "/" ]; then
    return 0
  fi

  [[ "$path" = "$prefix" || "$path" = "$prefix/"* ]]
}

path_in_allow_paths() {
  local path="$1"
  local allow_paths_csv="$2"
  local candidate
  local normalized_candidate

  if [ -z "$allow_paths_csv" ]; then
    return 1
  fi

  IFS=',' read -r -a candidates <<<"$allow_paths_csv"
  for candidate in "${candidates[@]}"; do
    normalized_candidate="$(normalize_allow_path_entry "$candidate")"
    if [ -n "$normalized_candidate" ] && path_is_under_prefix "$path" "$normalized_candidate"; then
      return 0
    fi
  done

  return 1
}

host_in_allow_urls() {
  local host="$1"
  local allow_urls_csv="$2"
  local candidate
  local normalized_candidate
  local normalized_host

  if [ -z "$allow_urls_csv" ]; then
    return 1
  fi

  normalized_host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  IFS=',' read -r -a candidates <<<"$allow_urls_csv"
  for candidate in "${candidates[@]}"; do
    normalized_candidate="$(normalize_allow_url_entry "$candidate")"
    if [ -n "$normalized_candidate" ] && [ "$normalized_candidate" = "$normalized_host" ]; then
      return 0
    fi
  done

  return 1
}

command_has_disallowed_url() {
  local command="$1"
  local allow_urls_csv="$2"
  local url
  local host

  if [ -z "$allow_urls_csv" ]; then
    return 1
  fi

  while IFS= read -r url; do
    if [ -z "$url" ]; then
      continue
    fi
    host="$(url_to_host "$url")"
    if [ -n "$host" ] && ! host_in_allow_urls "$host" "$allow_urls_csv"; then
      return 0
    fi
  done < <(extract_urls_from_command "$command")

  return 1
}

if [ -n "$TOOL_COMMAND" ]; then
  TOOL_COMMAND="$(normalize_spaces "$TOOL_COMMAND")"
fi

if [ -n "$CWD_PATH" ]; then
  CWD_PATH="$(normalize_tool_path "$CWD_PATH")"
fi

if [ -n "$TOOL_PATH" ]; then
  TOOL_PATH="$(resolve_tool_path "$TOOL_PATH" "$CWD_PATH")"
fi

if [ "$DEBUG_MODE" = "1" ]; then
  printf 'TOOL_NAME: %s\n' "$TOOL_NAME" >>"$DEBUG_PATH"
  printf 'CWD_PATH: %s\n' "$CWD_PATH" >>"$DEBUG_PATH"
  printf 'TOOL_COMMAND: %s\n' "$TOOL_COMMAND" >>"$DEBUG_PATH"
  printf 'TOOL_PATH: %s\n' "$TOOL_PATH" >>"$DEBUG_PATH"
fi

if [ -n "$TOOL_PATH" ]; then
  if [ -n "$CWD_PATH" ] && path_is_under_prefix "$TOOL_PATH" "$CWD_PATH"; then
    BODY=""
  elif path_in_allow_paths "$TOOL_PATH" "$ALLOW_PATHS"; then
    BODY=""
  elif [ -n "$TOOL_NAME" ]; then
    BODY="${TOOL_NAME}: ${TOOL_PATH}"
  else
    BODY="path: ${TOOL_PATH}"
  fi
elif [[ "$TOOL_NAME" = "ask_user" ]]; then
  BODY="$QUESTION"
elif [[ "$TOOL_NAME" = "exit_plan_mode" ]]; then
  BODY="$SUMMARY"
elif [[ "$TOOL_NAME" = "bash" ]]; then
  if [ -z "$TOOL_COMMAND" ]; then
    BODY="${TOOL_NAME}"
  elif matches_any_rule "$TOOL_NAME" "$TOOL_COMMAND" "$DENY_TOOL_RULES"; then
    BODY="${TOOL_NAME}"
  elif starts_with_token_prefix "$TOOL_COMMAND" "curl" &&
    command_has_disallowed_url "$TOOL_COMMAND" "$ALLOW_URLS"; then
    BODY="${TOOL_NAME}"
  elif matches_any_rule "$TOOL_NAME" "$TOOL_COMMAND" "$ALLOW_TOOL_RULES"; then
    BODY=""
  else
    BODY="${TOOL_NAME}"
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
