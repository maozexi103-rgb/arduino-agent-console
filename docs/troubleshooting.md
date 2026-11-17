# Troubleshooting

## No serial device or multiple devices

Use a USB data cable, not a charge-only cable. Match the device listed by Arduino IDE. Set `serial_port` to its exact `/dev/cu.*` name in the local config. Some clones require the manufacturer's USB driver. Automatic discovery refuses multiple matches.

Quit the bridge before a firmware upload or serial monitor. Reopening the serial port can reset an UNO. The bridge waits for the expected `VOICE_CONSOLE` startup and PONG handshake.

## Buttons work in firmware but not Codex

First test the corresponding keyboard shortcut in the installed app. Check the target bundle is `com.openai.codex`, the app path is correct and B1/B3 have Codex in front. In System Settings → Privacy & Security → Accessibility, enable the exact app you built.

After rebuilding, an old Accessibility entry can be stale even if its switch is on. Remove the old entry and add the new app through the normal system UI, then test a real button. Do not infer permission solely from the visible toggle.

## B3 removes one character or fails to clear

Bind Codex **Clear prompt** to `Control+Option+Shift+Backspace`, not forward Delete. An unbound shortcut can be interpreted as ordinary deletion. Test with a disposable draft.

## B3 cannot cancel dictation

The app searches exact localized names for the dedicated cancellation control and rejects generic Stop/Cancel. A changed UI label, missing Accessibility tree or window bounds can cause safe refusal. Finish/cancel with the normal interface, inspect the version and add a narrowly verified label before rebuilding. An API success return alone does not establish that recording ended.

## Red blink remains after hooks installation

Review and trust all seven hooks in Codex. Check the hook command still points to this checkout and an existing Python executable. Submit a real prompt after trusting. The observer also needs the local main-thread metadata schema; incompatible SQLite columns or an unconfirmed main task cause it to ignore the event. Missing state must not be presented as task completion.

## Green is on but the result is wrong

Expected: green indicates turn-ended/idle. It never checks whether code or generated files are correct. Review and test the result separately.

## The bridge's recording state drifted

Changing dictation using the mouse or keyboard bypasses its request-state tracking. End recording manually, then use the menu item that asks you to finish recording before reset. Do not send another blind toggle to guess the state.

## A downloaded app does not open

The release app is a local ad-hoc build, not an Apple-notarized distribution. Review the code and build from source using Apple's tools. The build produces the same inspectable source-based app, which you authorize through normal System Settings. This project does not remove quarantine attributes or bypass system permission checks.

For an issue, include OS/app version, board type and a redacted symptom. Do not attach raw conversation or authentication files.
