# Build journal

This is a summarized implementation record. It describes actual stages and evidence without publishing private chat logs or user-specific workspace identifiers.

## Physical controls

The design settled on four actions: start/stop dictation, open a new project chat, cancel/clear input, and toggle native live voice. Transcribed text stays in the input box for review, and the person sends it manually.

The three LEDs were tested individually, then the buttons were added one at a time. Dedicated bring-up sketches checked edges, counters and liveness. The four-button acceptance recorded three presses per button and twelve complete press/release pairs.

## Mac bridge

The first action used the app's own dictation shortcut. User observation confirmed the text remained unsent. New chat used an official deep link rather than sending a generic new-window shortcut to whichever app was frontmost.

Accessibility permission became stale after an application update. Toggling the switch did not fix it. Removing and re-adding the exact built app through normal System Settings restored behaviour, followed by combined first/second-button acceptance.

## Cancellation

Escape did not reliably cancel this version's dictation UI. A dedicated clear-prompt binding solved idle draft clearing. Active dictation needed its own dedicated control. An action-list precheck incorrectly excluded the right target. Later, an accessibility action returned success while recording continued.

The accepted solution validates the dedicated control's name, role, enabled state, owning process and live frame, clicks only within the focused window, then checks the control disappeared. The person confirmed that recording ended and the spoken input was discarded. A combined new-chat/dictate/clear/cancel regression followed.

## Fourth button and real task lights

The native live-call shortcut and then two physical B4 presses were observed to connect and end a call. The bridge records a toggle request, without reading call audio or claiming to observe call connection state.

Next, seven passive lifecycle hooks were added without replacing existing notification hooks. After review/trust, a real main task produced running yellow, question-wait red, resumed yellow after an answer, and turn-ended green. The next submission returned yellow. Old-chat/subagent isolation and privacy behaviour received regression checks. Actual permission-wait hardware acceptance remains outstanding.

## Presentation and public release

The console was used to help create a presentation: open a chat, dictate the request, answer clarification and review/send manually. That desktop recording contained private paths and conversation text, so the public demo uses hardware-only footage with audio removed. Desktop behaviour remains supported by the independent acceptance above.

The first public `0.5.1` release extracts the current source, adds optional app/workspace/serial configuration, builds in an isolated checkout, publishes exact wiring data, and documents setup, tests, privacy and known limitations. It does not modify the still-running prototype installation.
