# Privacy and local permissions

The bridge does not record audio, transcription, input-field values, clipboard contents or chat transcripts. It does not automatically send prompts or approve agent actions. Audio, transcription, account and network behaviour belong to the Codex application and its service.

Accessibility permission lets the bridge post the intended shortcuts and inspect control names/roles/children in the focused Codex window for the dedicated cancellation button. It checks a bounded live position before clicking that control. It does not request field-value attributes or generic stop-task controls.

The observer receives hook JSON, computes a hash for matching tool events, and persists only task metadata. It emits no decisions or injected prompt text. Its main-task filter queries selected local SQLite metadata columns read-only. The installer merges definitions, keeps other hooks, writes a backup and leaves trust review to Codex.

Local records are still private metadata:

- Thread/turn identifiers, timestamps, event names and task states can appear in state/audit files.
- Bridge logs can include the chosen workspace path, serial path, process IDs, command names and app errors.
- `config.json` contains your local paths.
- File protection is best-effort POSIX permissions, not encryption. The hook state and transition audit use 0600 files, and the public bridge creates its logs with 0600 permissions.

Review and redact local files before posting an issue. Never upload hook backups, authentication config, raw desktop recordings or your whole Codex directory. The public repo contains hardware media and a summarized build journal, not the developer's private runtime logs or original conversation recordings.

## Removing observers

Quit the bridge after finishing active dictation. Use `python3 tools/install_agent_hooks.py --uninstall` from the installed checkout to remove only its exact observer commands. Review remaining definitions in Codex. Remove the app's Accessibility entry through System Settings if you no longer use it. Inspect local metadata before deleting it yourself.
