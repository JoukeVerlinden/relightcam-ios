// relightCam light dome controller, USB MIDI variant (controller wired to the iPhone)
// For boards that can be a USB MIDI device with the MIDIUSB library: Arduino Leonardo, Micro,
// Pro Micro (ATmega32U4) and the SAMD boards. NOT the UNO R4: its core has USB MIDI switched off, so
// use the Bluetooth sketch (relightcam_dome) there.
// LEDs: WS2812B-style RGBW strip (NeoPixel, GRBW order) on pin 6.
// The board appears on the iPhone as a USB MIDI device; relightCam switches the LEDs over CoreMIDI:
//
//   channel 1, LED n (counted from 0) = MIDI note n
//   Note On  -> LED n white, brightness = velocity (127 = full); other LEDs off
//   Note Off -> LED n off
//   Control Change 123 (All Notes Off) or 120 (All Sound Off) -> all LEDs off
//
// Libraries (Arduino IDE > Library Manager): Adafruit NeoPixel, MIDIUSB.
// In relightCam: capture screen > interval menu > Dome. The board shows up in the dome row by itself.
//
// Compiles for the Leonardo (arduino:avr:leonardo); not yet run with a strip. Check the pixel order
// (NEO_GRBW) and the LED count.

#include <Adafruit_NeoPixel.h>
#include <MIDIUSB.h>

const int LED_PIN = 6;
const int NUM_LEDS = 55;

Adafruit_NeoPixel strip(NUM_LEDS, LED_PIN, NEO_GRBW + NEO_KHZ800);

void allOff() {
  strip.clear();
  strip.show();
}

void ledOn(byte n, byte velocity) {
  if (n >= NUM_LEDS) return;
  // one LED at a time: a photo must be lit by a single, known LED
  strip.clear();
  strip.setPixelColor(n, strip.Color(0, 0, 0, map(velocity, 1, 127, 2, 255)));  // white channel only
  strip.show();
}

void ledOff(byte n) {
  if (n >= NUM_LEDS) return;
  strip.setPixelColor(n, 0);
  strip.show();
}

void setup() {
  strip.begin();
  allOff();
}

void loop() {
  midiEventPacket_t rx = MidiUSB.read();
  if (rx.header == 0) return;  // nothing received
  byte type = rx.byte1 & 0xF0, d1 = rx.byte2, d2 = rx.byte3;
  if (type == 0x90 && d2 > 0) ledOn(d1, d2);
  else if (type == 0x80 || type == 0x90) ledOff(d1);
  else if (type == 0xB0 && (d1 == 123 || d1 == 120)) allOff();
}
