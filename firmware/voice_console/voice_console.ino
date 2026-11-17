// Same proven wiring: B1=D8, B2=D9, B3=D11, B4=D12; LEDs R=D2 Y=D3 G=D4.
// Mac/Codex owns audio and AI. The bridge maps real lifecycle states to LED color codes.
#include <stdio.h>
const byte BUTTON_PINS[] = {8, 9, 11, 12};
struct Button { byte raw, stable; unsigned long changedAt, downAt, count; };
Button buttons[4];
enum Mode : byte { OFFLINE, READY, RECORDING, REVIEW, ERROR_MODE };
const char *const MODE_NAMES[] = {"OFFLINE", "READY", "RECORDING", "REVIEW", "ERROR"};
Mode mode = OFFLINE;
unsigned long hostAt = 0, heartbeatAt = 0, heartbeats = 0;
char command[64];
byte used = 0;
bool overflow = false;

void handleCommand() {
  if (strcmp(command, "PING") == 0) {
    hostAt = millis();
    Serial.println(F("PONG VOICE_CONSOLE"));
    return;
  }
  char name[16];
  unsigned long id;
  if (sscanf(command, "SET %15s %lu", name, &id) == 2) {
    for (byte i = 0; i < 5; ++i) {
      if (strcmp(name, MODE_NAMES[i]) == 0) {
        mode = static_cast<Mode>(i);
        hostAt = millis();
        Serial.print(F("ACK ")); Serial.print(id); Serial.print(' '); Serial.println(name);
        return;
      }
    }
  }
  Serial.println(F("ERR UNKNOWN_COMMAND"));
}

void setup() {
  const byte outputs[] = {2, 3, 4, 10};
  for (byte i = 0; i < 4; ++i) { digitalWrite(outputs[i], LOW); pinMode(outputs[i], OUTPUT); }
  for (byte i = 0; i < 4; ++i) {
    pinMode(BUTTON_PINS[i], INPUT_PULLUP);
    buttons[i].raw = buttons[i].stable = digitalRead(BUTTON_PINS[i]);
    buttons[i].changedAt = buttons[i].downAt = millis();
  }
  Serial.begin(115200);
  Serial.println(F("VOICE_CONSOLE READY B1=D8 B2=D9 B3=D11 B4=D12"));
}

void loop() {
  const unsigned long now = millis();
  for (byte i = 0; i < 4; ++i) {
    Button &b = buttons[i];
    const byte raw = digitalRead(BUTTON_PINS[i]);
    if (raw != b.raw) { b.raw = raw; b.changedAt = now; }
    if (b.stable != b.raw && now - b.changedAt >= 30UL) {
      b.stable = b.raw;
      Serial.print(F("EVENT B")); Serial.print(i + 1);
      if (b.stable == LOW) {
        b.downAt = now;
        Serial.print(F(" DOWN count=")); Serial.println(++b.count);
      } else {
        Serial.print(F(" UP held_ms=")); Serial.println(now - b.downAt);
      }
    }
  }
  if (now - hostAt > 8000UL) mode = OFFLINE;
  digitalWrite(2, (mode == ERROR_MODE || (mode == OFFLINE && now % 1600UL < 120UL)) ? HIGH : LOW);
  digitalWrite(3, (mode == RECORDING || mode == REVIEW) ? HIGH : LOW);
  digitalWrite(4, (mode == READY || mode == REVIEW) ? HIGH : LOW);
  // D10 is reserved and held LOW. It is not part of the four-button, three-LED circuit.
  digitalWrite(10, LOW);
  if (now - heartbeatAt >= 1000UL) {
    heartbeatAt = now;
    Serial.print(F("ALIVE ")); Serial.print(++heartbeats);
    Serial.print(F(" MODE=")); Serial.println(MODE_NAMES[mode]);
  }
  while (Serial.available()) {
    char ch = Serial.read();
    if (ch == '\r') continue;
    if (ch == '\n') {
      if (!overflow) { command[used] = '\0'; handleCommand(); }
      used = 0; overflow = false;
    } else if (!overflow && used < sizeof(command) - 1) command[used++] = ch;
    else overflow = true;
  }
}
