# Reference projects and sources

These projects informed how this repository is organized: show a working device, list hardware, explain the host/firmware split, provide build steps, describe the protocol, and state limits. Their code was not copied into this project, and their features are not claimed here.

- [MacroPad Serial To Macros GUI](https://github.com/Brimgit/MacroPad-Serial-To-Macros-GUI): separates device firmware, host application, serial protocol and hardware design files.
- [ESPDeck](https://github.com/mahimchowdhurymiraj/ESPDeck): presents hardware/software prerequisites, configuration, step-by-step setup and troubleshooting together.
- [Stream Deck with Arduino Uno](https://github.com/denism17/stream-deck-arduino): an example of documenting an Arduino-based desktop control surface.

Primary platform references checked while preparing the release:

- [Codex hooks and review/trust](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks).
- [Codex commands and new-chat deep links](https://learn.chatgpt.com/docs/reference/commands#chats).
- [Arduino CLI getting started](https://docs.arduino.cc/arduino-cli/getting-started/).
- [GitHub Pages](https://docs.github.com/en/pages).

Shortcuts and the dedicated cancellation labels came from the locally tested app and user acceptance, not from a promised stable third-party API. The read-only SQLite thread filter is explicitly an internal compatibility dependency.
