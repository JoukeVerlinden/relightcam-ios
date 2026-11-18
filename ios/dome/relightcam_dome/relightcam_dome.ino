// relightCam light dome controller
// Board: Arduino UNO R4 WiFi. LEDs: WS2812B-style RGBW strip (NeoPixel, GRBW order) on pin 6.
// relightCam switches the LEDs over Bluetooth MIDI (CoreMIDI on the iPhone):
//
//   channel 1, LED n (counted from 0) = MIDI note n
//   Note On  -> LED n white, brightness = velocity (127 = full); other LEDs off
//   Note Off -> LED n off
//   Control Change 123 (All Notes Off) or 120 (All Sound Off) -> all LEDs off
//
// Libraries (Arduino IDE > Library Manager): Adafruit NeoPixel, ArduinoBLE.
// The sketch implements the BLE-MIDI service itself (Bluetooth SIG / MMA "MIDI over Bluetooth LE"),
// so no MIDI library is needed.
// In relightCam: capture screen > interval menu > Dome > dome row > Connect a Bluetooth MIDI device,
// pick "relightCam dome". The board's LED (L) is on while connected.
// Serial monitor (115200 baud) logs connections and every LED change.
//
// For a cable to the iPhone instead, use relightcam_dome_usb (USB MIDI, needs ../r4-usb-midi/patch_core.py).
// Check the pixel order (NEO_GRBW) and the LED count against your strip.

#include <ArduinoBLE.h>
#include <Adafruit_NeoPixel.h>

const int LED_PIN = 6;
const int NUM_LEDS = 24;  // LEDs on the strip (the current dome has 24)
const char *DOME_NAME = "relightCam dome";
const bool LOG = true;

Adafruit_NeoPixel strip(NUM_LEDS, LED_PIN, NEO_GRBW + NEO_KHZ800);

// BLE-MIDI service and its single characteristic (fixed UUIDs from the specification)
BLEService midiService("03B80E5A-EDE8-4B33-A751-6CE34EC4C700");
BLECharacteristic midiChar("7772E5DB-3868-4112-A1A9-F2669D106BF3",
                           BLERead | BLEWrite | BLEWriteWithoutResponse | BLENotify, 128);

void allOff() {
  strip.clear();
  strip.show();
  if (LOG) Serial.println("all off");
}

void ledOn(byte n, byte velocity) {
  if (n >= NUM_LEDS) return;
  // one LED at a time: a photo must be lit by a single, known LED
  strip.clear();
  strip.setPixelColor(n, strip.Color(0, 0, 0, map(velocity, 1, 127, 2, 255)));  // white channel only
  strip.show();
  if (LOG) { Serial.print("on "); Serial.print(n + 1); Serial.print(" ("); Serial.print(velocity); Serial.println(")"); }
}

void ledOff(byte n) {
  if (n >= NUM_LEDS) return;
  strip.setPixelColor(n, 0);
  strip.show();
}

void handleMidi(byte status, byte d1, byte d2) {
  byte type = status & 0xF0;
  if (type == 0x90 && d2 > 0) ledOn(d1, d2);
  else if (type == 0x80 || type == 0x90) ledOff(d1);
  else if (type == 0xB0 && (d1 == 123 || d1 == 120)) allOff();
}

// A BLE-MIDI packet: header byte, then [timestamp byte][status byte][data...] messages. Status bytes are
// always preceded by a timestamp byte; running status (data without a new status) is allowed.
void parseBleMidi(const uint8_t *p, int n) {
  if (n < 3 || !(p[0] & 0x80)) return;
  byte status = 0, data[2] = {0, 0};
  int have = 0, need = 0;
  for (int i = 1; i < n; i++) {
    byte b = p[i];
    if (b & 0x80) {                       // timestamp byte
      have = 0;
      if (i + 1 < n && (p[i + 1] & 0x80)) {
        b = p[++i];                       // status byte
        if (b >= 0xF0) { status = 0; continue; }  // system messages (SysEx etc.) are not used
        status = b;
        need = ((b & 0xF0) == 0xC0 || (b & 0xF0) == 0xD0) ? 1 : 2;
      }
      continue;
    }
    if (!status) continue;
    data[have++] = b;
    if (have == need) {
      handleMidi(status, data[0], need > 1 ? data[1] : 0);
      have = 0;
    }
  }
}

void onWritten(BLEDevice central, BLECharacteristic c) {
  parseBleMidi(c.value(), c.valueLength());
}

void onConnected(BLEDevice central) {
  digitalWrite(LED_BUILTIN, HIGH);
  if (LOG) { Serial.print("connected: "); Serial.println(central.address()); }
}

void onDisconnected(BLEDevice central) {
  digitalWrite(LED_BUILTIN, LOW);
  allOff();  // never leave an LED burning when the phone goes away
  if (LOG) Serial.println("disconnected");
}

void setup() {
  Serial.begin(115200);
  pinMode(LED_BUILTIN, OUTPUT);
  strip.begin();
  allOff();
  delay(3000);  // time to open the serial monitor after an upload or reset
  Serial.println("relightCam dome: starting Bluetooth");

  if (!BLE.begin()) {
    // usually old ESP32 firmware: Arduino IDE > Tools > Firmware Updater
    while (true) {
      Serial.println("Bluetooth didn't start: update the UNO R4 WiFi's ESP32 firmware");
      digitalWrite(LED_BUILTIN, !digitalRead(LED_BUILTIN));
      delay(250);
    }
  }
  BLE.setLocalName(DOME_NAME);
  BLE.setDeviceName(DOME_NAME);
  BLE.setAdvertisedService(midiService);
  midiService.addCharacteristic(midiChar);
  BLE.addService(midiService);
  BLE.setEventHandler(BLEConnected, onConnected);
  BLE.setEventHandler(BLEDisconnected, onDisconnected);
  midiChar.setEventHandler(BLEWritten, onWritten);
  BLE.advertise();
  Serial.print("advertising as \"");
  Serial.print(DOME_NAME);
  Serial.println("\" with the Bluetooth MIDI service");
}

void loop() {
  BLE.poll();
  // until the phone connects, say so every 5 s (the start-up message is easy to miss)
  static unsigned long lastStatus = 0;
  if (!BLE.connected() && millis() - lastStatus > 5000) {
    lastStatus = millis();
    Serial.print("advertising as \"");
    Serial.print(DOME_NAME);
    Serial.println("\", waiting for relightCam");
  }
}
