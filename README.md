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

## Install

```bash
copilot plugin install tadashi-aikawa/copilot-plugin-notify
```

## Environment variables


| Name                                         | Description                                                                                     | Default                     |
| -------------------------------------------- | ----------------------------------------------------------------------------------------------- | --------------------------- |
| `COPILOT_NOTIFY_ALLOW_TOOL_RULES`            | comma-separated allow rules (e.g. `shell(git:*),shell(gh:*),shell(curl),write`)               |                             |
| `COPILOT_NOTIFY_DENY_TOOL_RULES`             | comma-separated deny rules (e.g. `shell(git push),shell(git reset:*),shell(gh api)`)          |                             |
| `COPILOT_NOTIFY_ALLOW_URLS`                  | comma-separated allowed hosts for URL access checks in `curl` commands                         |                             |
| `COPILOT_NOTIFY_DEBUG`                       | set to `1` to enable debug logging (input/debug log + extra `agentStop` dump)                 |                             |
| `COPILOT_NOTIFY_DEBUG_PATH`                  | debug log path used when `COPILOT_NOTIFY_DEBUG=1`                                              | `/tmp/copilot-notify.jsonl` |
| `COPILOT_NOTIFY_FORCE_STDOUT`                | set to `1` to emit OSC 777 to stdout instead of `/dev/tty`                                     | `0`                         |
| `COPILOT_NOTIFY_AGENTSTOP_POLL_ATTEMPTS`     | number of retries when waiting for the latest `assistant.message` after `agentStop`            | `10`                        |
| `COPILOT_NOTIFY_AGENTSTOP_POLL_INTERVAL_SEC` | interval seconds between retries                                                                | `0.05`                      |
| `COPILOT_NOTIFY_AGENTSTOP_ACCEPTABLE_AGE_MS` | maximum age from hook input timestamp for candidate messages to avoid stale notifications       | `3000`                      |

### Example

```bash
export COPILOT_NOTIFY_ALLOW_TOOL_RULES="write,shell(git:*),shell(gh:*),shell(curl)"
export COPILOT_NOTIFY_DENY_TOOL_RULES="shell(git push),shell(git reset:*),shell(git clean:*),shell(gh api),shell(gh pr merge)"
export COPILOT_NOTIFY_ALLOW_URLS="api.github.com,raw.githubusercontent.com,github.com"
```

## Developer notes

### Files

- `plugin.json`: Plugin metadata
- `hooks.json`: Registers `preToolUse` and `agentStop` hooks
- `scripts/notify.sh`: Reads hook payload from stdin and emits OSC 777 notification sequences to /dev/tty

### Notes

- Hook payload is read from stdin (JSON).
- `preToolUse`:
  - `bash`: notify with `bash`, but only when the command should be notified by tool rules.
  - `edit`: notify with `edit: <toolArgs.path>`.
- `ask_user`: notify with `toolArgs.question` (newlines are normalized to spaces).
- `exit_plan_mode`: notify with `toolArgs.summary` (newlines are normalized to spaces).
- `agentStop`: notify when Copilot finishes an agent turn and waits for user input.
- `bash` rule matching:
  - `deny` has highest priority, then `allow`, then notify by default.
  - `shell(x:*)` and `shell(x)` both match when command starts with `x` (`x` alone or `x ...`).
  - `curl` command checks `COPILOT_NOTIFY_ALLOW_URLS`; if any URL host is not allowed, it is notified.
  - Unknown/unmatched commands are notified.
