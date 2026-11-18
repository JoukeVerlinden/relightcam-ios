// relightCam light dome controller
// Board: Arduino UNO R4 WiFi. LEDs: WS2812B-style RGBW strip (NeoPixel, GRBW order) on pin 6.
// relightCam switches the LEDs over Bluetooth MIDI (CoreMIDI on the iPhone):
//
//   channel 1, LED n (counted from 0) = MIDI note n
//   Note On  -> LED n white, brightness = velocity (127 = full); other LEDs off
//   Note Off -> LED n off
//   Control Change 123 (All Notes Off) or 120 (All Sound Off) -> all LEDs off
//
// Libraries (Arduino IDE > Library Manager):
//   Adafruit NeoPixel, ArduinoBLE, MIDI Library (FortySevenEffects), BLE-MIDI (lathoub)
// In relightCam: capture screen > interval menu > Dome > dome row > Connect a Bluetooth MIDI device,
// pick "relightCam dome". The board's LED (L) is on while connected.
//
// Untested sketch: check the pixel order (NEO_GRBW) and the LED count against your strip.

#include <Adafruit_NeoPixel.h>
#include <BLEMIDI_Transport.h>
#include <hardware/BLEMIDI_ArduinoBLE.h>

const int LED_PIN = 6;
const int NUM_LEDS = 55;

Adafruit_NeoPixel strip(NUM_LEDS, LED_PIN, NEO_GRBW + NEO_KHZ800);
BLEMIDI_CREATE_INSTANCE("relightCam dome", MIDI)

void allOff() {
  strip.clear();
  strip.show();
}

void onNoteOff(byte channel, byte note, byte velocity) {
  if (note >= NUM_LEDS) return;
  strip.setPixelColor(note, 0);
  strip.show();
}

void onNoteOn(byte channel, byte note, byte velocity) {
  if (note >= NUM_LEDS) return;
  if (velocity == 0) { onNoteOff(channel, note, velocity); return; }
  // one LED at a time: a photo must be lit by a single, known LED
  strip.clear();
  strip.setPixelColor(note, strip.Color(0, 0, 0, map(velocity, 1, 127, 2, 255)));  // white channel only
  strip.show();
}

void onControlChange(byte channel, byte number, byte value) {
  if (number == 123 || number == 120) allOff();
}

void onConnected() {
  digitalWrite(LED_BUILTIN, HIGH);
}

void onDisconnected() {
  digitalWrite(LED_BUILTIN, LOW);
  allOff();  // never leave an LED burning when the phone goes away
}

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  strip.begin();
  allOff();
  MIDI.begin(MIDI_CHANNEL_OMNI);  // also starts Bluetooth advertising
  BLEMIDI.setHandleConnected(onConnected);
  BLEMIDI.setHandleDisconnected(onDisconnected);
  MIDI.setHandleNoteOn(onNoteOn);
  MIDI.setHandleNoteOff(onNoteOff);
  MIDI.setHandleControlChange(onControlChange);
}

void loop() {
  MIDI.read();
}
