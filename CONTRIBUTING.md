# Contributing

Start with an issue describing the behaviour and the tested OS/Codex/board versions. Redact local paths, task identifiers and content from logs.

Run the Python tests and wiring/release checks before a pull request. On macOS run `bash macos/build.sh`. Compile the UNO sketch without uploading to someone else's connected device.

Preserve manual prompt review and sending. Keep the bridge's dedicated cancellation target narrow. Do not treat missing state as completion, green as correctness, a button press as agent activity, or an accessibility return code as a confirmed interface outcome.

For physical or UI changes, describe what a person actually observed, separately from software self-tests. Include a reproducible acceptance procedure. Do not claim a new OS, board or app version is supported only because it compiles.

Contributions are submitted under this repository's MIT license. Avoid vendoring platform binaries or copying code without preserving its license.
