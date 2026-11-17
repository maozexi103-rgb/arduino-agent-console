# Build and run

Allow time for your own physical acceptance. A successful compile does not verify your switches, permissions or the current Codex UI.

## 1. Prepare the hardware and firmware

Use the [parts and wiring guide](hardware.md). Disconnect USB while changing wires. Keep each LED's 220 Ω resistor in series. Buttons use the internal pull-up and connect to GND when pressed.

In Arduino IDE, open `firmware/voice_console/voice_console.ino`, select Arduino UNO and your USB port, then upload. Quit the bridge before uploading or using Serial Monitor. Only one program may own the serial port.

Optional compile-only check:

```bash
arduino-cli core update-index
arduino-cli core install arduino:avr@1.8.8
arduino-cli compile --fqbn arduino:avr:uno firmware/voice_console
```

Compile does not upload or connect to the board.

## 2. Build the Mac bridge

Install Apple's Command Line Tools if needed (`xcode-select --install`), then:

```bash
git clone https://github.com/maozexi103-rgb/arduino-agent-console.git
cd arduino-agent-console
bash macos/build.sh
```

The script builds for the Mac's current architecture with deployment target 13.0, signs locally, and runs `--self-test`. It writes only `dist/` and `.build/` inside this checkout. It does not launch the normal app, open USB, install hooks or post keyboard/mouse events.

An arm64 app is available in [Releases](https://github.com/maozexi103-rgb/arduino-agent-console/releases/latest). It is ad-hoc signed and not notarized. Inspect the source and build locally if macOS does not accept the downloaded app. Rebuilding can require re-registering Accessibility permission.

## 3. Configure the target and project

The app reads this optional local file at startup:

```text
~/Library/Application Support/ArduinoVoiceBridge/config.json
```

Create the directory and copy the template:

```bash
mkdir -p "$HOME/Library/Application Support/ArduinoVoiceBridge"
cp macos/config.example.json "$HOME/Library/Application Support/ArduinoVoiceBridge/config.json"
```

Edit the copied file. All fields are optional:

| Key | If omitted | If supplied |
|---|---|---|
| `workspace_path` | Repository root when the app remains in `repo/dist/` | Absolute path to your coding project |
| `codex_app_path` | macOS lookup for bundle ID `com.openai.codex` | Absolute path to that app bundle |
| `serial_port` | Auto-discover one `cu.usbmodem*`, `cu.usbserial*` or `cu.wchusbserial*` port | Exact `/dev/cu.*` device |

The template values are examples. Replace them or remove the keys. An empty object `{}` uses all defaults. If you move the app elsewhere, set `workspace_path` explicitly. If several serial devices are connected, select one explicitly. App targets must match the Codex bundle ID, not merely a similar file name.

## 4. Verify the desktop shortcuts

Before pressing the hardware controls:

1. In the installed Codex app, verify `Cmd+Shift+D` starts and stops dictation. Finish the test without sending.
2. In Settings → Keyboard shortcuts, assign **Clear prompt** to `Ctrl+Option+Shift+Backspace` (the normal backward-delete key).
3. Verify `Ctrl+Shift+V` starts and ends the native live voice call. End the call before continuing.
4. Run `dist/Arduino Voice Bridge.app`. In System Settings → Privacy & Security → Accessibility, add and enable that exact app. Keep Codex's microphone/account/network setup separate from the bridge.
5. Open a Codex input box and press B1 twice. Review the resulting draft and send only if you intend to. B2 and B4 may activate Codex. B1 and B3 require it in front.

Shortcut availability can differ by version or account. If the keyboard shortcut itself fails, fix or remap that action before assuming the Arduino is faulty. The public app currently keeps these bindings in Swift source.

## 5. Install and review task hooks

Python 3.9+ is required. No third-party Python runtime dependencies are needed.

```bash
python3 tools/install_agent_hooks.py
python3 tools/install_agent_hooks.py --install
```

The first command is a preview. The second backs up and merges definitions into `$CODEX_HOME/hooks.json`, or `~/.codex/hooks.json`. Keep this checkout and its Python executable in place after installation, because hook commands use absolute paths.

Review all seven new observer definitions in Codex **Settings → Hooks**, or `/hooks` in the CLI. New or changed hooks remain skipped until trusted. The installer does not change trust hashes or approval decisions. Existing sound hooks remain intact.

Submit a real task. Yellow should mean running, red should appear for a real question, and green should appear when that turn ends. Unknown state uses a short red blink. See [task selection details](architecture.md#task-selection).

## 6. Recover and uninstall

- If dictation was toggled using a mouse/keyboard, finish it manually first, then use the bridge menu's reset item.
- Finish dictation and live calls before quitting. Quitting the bridge does not hang up a call for you.
- Quit the bridge before firmware uploads or serial-monitor use.
- To remove this checkout's hook definitions while preserving others:

  ```bash
  python3 tools/install_agent_hooks.py --uninstall
  ```

  Then review Hooks in Codex. The uninstall helper does not edit trust records. If you moved the checkout, run the helper from the original path or remove the exact old definitions in Codex.
- Remove the app from Accessibility if no longer used. Local metadata remains in `~/Library/Application Support/ArduinoVoiceBridge/` and `~/Library/Logs/ArduinoVoiceBridge/`; inspect before deleting it yourself.

[Troubleshooting](troubleshooting.md) · [Acceptance checklist](testing.md)
