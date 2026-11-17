# Tests and acceptance

## Automated checks

```bash
python3 -m unittest discover -s tools -p 'test_*.py' -v
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 tools/check_release.py
bash macos/build.sh
```

Python lifecycle fixtures operate in temporary directories. They do not inject status into a real task. Swift `--self-test` exercises press routing, deduplication, configuration parsing, deep-link encoding, cancellation bounds and snapshot/color mapping without running the app or posting input.

Wiring tests model both common internally paired switch layouts and every single-button press. They check unique hole occupancy, button-to-ground behaviour, independent outputs and resistors that are neither bypassed nor directly shorted to ground.

CI compiles firmware but never uploads it. Running these software checks does not confirm physical wiring or a new Codex version's UI behaviour.

## Original physical acceptance

On 2026-11-17, the deployed `0.5.0` prototype received these checks:

| Level | Evidence | Accepted outcome |
|---|---|---|
| Buttons | Three presses on each of four switches | Twelve matched DOWN/UP pairs |
| B1 | Desktop observation and event/ACK logs | Start/stop, draft stays unsent, human sends |
| B2 | Desktop observation | Bring Codex forward, open new project chat |
| B3 | Desktop observation and dedicated-control disappearance | Cancel/discard dictation, clear unsent draft |
| B4 | Physical switch toggles, observed in desktop | Native call connected and ended |
| Task lights | Real hooks, bridge requests, UNO ACKs and physical observation | Running yellow, question red, answer yellow, turn-ended green, next turn yellow |
| State logic | Nine original state/privacy/merge tests | Passed in the prototype environment |

An actual permission-request wait branch has **not** received physical acceptance. Its mapping is regression-tested. Call connection state is not read by the bridge. No productivity benchmark or comparative usability test exists.

Public `0.5.1` keeps the same button/LED protocol and adds portable configuration and build packaging. Its automated checks do not constitute another physical acceptance of those changes.

## Repeat on your own setup

1. Check that each press causes one intended action. Confirm release events without relying solely on LED color.
2. B1: dictate a disposable sentence, stop, confirm text remains unsent. Review before sending.
3. B2: from another app, press once and confirm a new chat in your configured workspace. Return to the old chat afterward if needed.
4. B3: cancel an active disposable dictation. Confirm recording stops and the sentence never enters the draft. Separately clear a disposable draft.
5. B4: connect and end a call, checking the Codex interface each time.
6. Submit a real task, observe yellow, encounter a real question, observe red, answer, observe yellow, then observe green at the end of the turn. Inspect the output regardless of color.
7. Finish dictation before any reconnect/reset/upload. Do not use a test monitor while the bridge owns the port.
