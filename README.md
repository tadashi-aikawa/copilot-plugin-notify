# copilot-plugin-notify

> ⚠️ IMPORTANT — Temporary workaround
>
> This plugin is a temporary shim until the following upstream Copilot CLI issues are resolved:
>
> - https://github.com/github/copilot-cli/issues/1067
> - https://github.com/github/copilot-cli/issues/1128
>
> Remove this plugin once those issues are fixed.
>
Copilot CLI hook events are emitted as OSC 777 notification escape sequences; listeners such as cmux can consume these notifications.

## Files

- `plugin.json`: Plugin metadata
- `hooks.json`: Registers `preToolUse` and `agentStop` hooks
- `scripts/notify.sh`: Reads hook payload from stdin and emits OSC 777 notification sequences to /dev/tty

## Install

```bash
copilot plugin install tadashi-aikawa/copilot-plugin-notify
```

## Notes

- Hook payload is read from stdin (JSON).
- `preToolUse`: notify only for selected tool names (default: `bash`).
- `agentStop`: notify when Copilot finishes an agent turn and waits for user input.

## Environment variables


| Name                                         | Description                                                                               | Default      |
| -------------------------------------------- | ----------------------------------------------------------------------------------------- | ------------ |
| `COPILOT_NOTIFY_PRETOOL_TOOLS`               | comma-separated tool names for `preToolUse` notifications                                 | `shell,bash` |
| `COPILOT_NOTIFY_DEBUG`                       | set to `1` to append `agentStop` payload JSON into `/tmp/copilot-notify-agent-stop.jsonl` |              |
| `COPILOT_NOTIFY_AGENTSTOP_POLL_ATTEMPTS`     | number of retries when waiting for the latest `assistant.message` after `agentStop`       | `10`         |
| `COPILOT_NOTIFY_AGENTSTOP_POLL_INTERVAL_SEC` | interval seconds between retries                                                          | `0.05`       |
| `COPILOT_NOTIFY_AGENTSTOP_ACCEPTABLE_AGE_MS` | maximum age from hook input timestamp for candidate messages to avoid stale notifications | `3000`       |


