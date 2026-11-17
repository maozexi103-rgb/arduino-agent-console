# Architecture and protocol

## Responsibilities

The UNO detects four independent button edges, debounces them for 30 ms, reports press/release events, and drives three LEDs. It does not record audio or run AI.

The Swift menu-bar bridge exclusively owns the serial device, validates press counts, applies a 500 ms accidental-repeat gate per button, and sends input only to the intended desktop app. B1/B3 require Codex in front. B2 uses a new-chat deep link. B4 activates the configured Codex bundle before sending a live-call toggle.

B3 cancellation searches the focused window for an enabled, specifically named dictation-cancel button. It validates its process, role, live frame and window bounds before clicking. It then checks whether the cancel control disappears. Generic Stop/Cancel task controls are excluded. Idle draft clearing uses a dedicated configured shortcut.

## Task selection

Seven passive hooks feed `tools/codex_agent_state_hook.py`: `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Stop`, `Interrupt`, `SessionEnd`.

Only `UserPromptSubmit` selects a different main task. Other sessions and older turns cannot overwrite the selection. Question/permission matches are stored as metadata and argument hashes, not raw questions or commands. Async-question tool completion means the question appeared, so it stays waiting until the next real submission. A matching synchronous answer/tool completion can resume work.

Main-thread filtering first rejects explicit subagent identities, then reads selected metadata columns (`source`, `thread_source`, `agent_path`) from the latest numeric `state_*.sqlite` under the Codex config directory, opened read-only. This internal SQLite dependency is version-sensitive. If no compatible main-thread metadata can be confirmed, the event is ignored. It never reads transcripts to infer task progress.

The bridge reads `agent-state.json` once a second. It does not treat a button press as proof that the agent is working. Missing state or an unavailable app yields unknown. The last observed lifecycle event is not proof of continued work after an abnormal exit.

## USB protocol

115200 baud, newline-delimited ASCII. UNO resets when the port opens on typical boards.

```text
UNO: VOICE_CONSOLE READY B1=D8 B2=D9 B3=D11 B4=D12
Mac: PING
UNO: PONG VOICE_CONSOLE
UNO: EVENT B1 DOWN count=1
UNO: EVENT B1 UP held_ms=104
Mac: SET RECORDING 7
UNO: ACK 7 RECORDING
UNO: ALIVE 3 MODE=RECORDING
```

`SET MODE ID` accepts `OFFLINE`, `READY`, `RECORDING`, `REVIEW`, `ERROR`. These legacy names are color codes:

| Mode code | Electrical output | Current lifecycle mapping |
|---|---|---|
| OFFLINE | Short red pulse | Unknown/unavailable |
| READY | Green | DONE or IDLE |
| RECORDING | Yellow | RUNNING |
| ERROR | Red | WAITING or bridge fault |
| REVIEW | Yellow + green | Compatibility code, not used for normal task lights |

The bridge sends `PING` every 2 seconds. It reconnects after 6 seconds without serial data. The UNO falls back to OFFLINE after 8 seconds without a valid host command. This is liveness checking, not task-success detection.

## Local files

`~/Library/Application Support/ArduinoVoiceBridge/` contains `config.json`, `agent-state.json`, a lock and transition audit. Bridge events are under `~/Library/Logs/ArduinoVoiceBridge/`. See [privacy](privacy.md) for what those metadata files can reveal.
