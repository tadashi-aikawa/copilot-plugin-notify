# cmux-notify plugin

Copilot CLI hook events are forwarded to `cmux notify`.

## Files

- `plugin.json`: Plugin metadata
- `hooks.json`: Registers `preToolUse` and `agentStop` hooks
- `scripts/cmux-notify.sh`: Reads hook payload from stdin and calls `cmux notify`

## Install

```bash
copilot plugin install tadashi-aikawa/copilot-plugin-cmux-notify
```

## Notes

- Hook payload is read from stdin (JSON).
- `preToolUse`: notify only for selected tool names (default: `shell,bash`).
- `agentStop`: notify when Copilot finishes an agent turn and waits for user input.

## Environment variables

- `CMUX_NOTIFY_PRETOOL_TOOLS`: comma-separated tool names for `preToolUse` notifications (default: `shell,bash`)
- `CMUX_NOTIFY_DEBUG`: set to `1` to append `agentStop` payload JSON into `/tmp/cmux-notify-agent-stop.jsonl`
- `CMUX_NOTIFY_AGENTSTOP_POLL_ATTEMPTS`: number of retries when waiting for the latest `assistant.message` after `agentStop` (default: `10`)
- `CMUX_NOTIFY_AGENTSTOP_POLL_INTERVAL_SEC`: interval seconds between retries (default: `0.05`)
- `CMUX_NOTIFY_AGENTSTOP_ACCEPTABLE_AGE_MS`: maximum age (ms) from hook input timestamp for candidate messages to avoid stale notifications (default: `3000`)
