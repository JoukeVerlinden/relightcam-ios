// relightCam light dome controller, USB MIDI (controller wired to the iPhone)
// LEDs: WS2812B-style RGBW strip (NeoPixel, GRBW order) on pin 6.
// The board appears on the iPhone as a class-compliant USB MIDI device; relightCam switches the LEDs
// over CoreMIDI:
//
//   channel 1, LED n (counted from 0) = MIDI note n
//   Note On  -> LED n white, brightness = velocity (127 = full); other LEDs off
//   Note Off -> LED n off
//   Control Change 123 (All Notes Off) or 120 (All Sound Off) -> all LEDs off
//
// Boards:
//   Arduino UNO R4 WiFi: needs the USB MIDI patch for the UNO R4 core first
//     (python3 ../r4-usb-midi/patch_core.py; re-run after updating the board package).
//   Leonardo, Micro, Pro Micro (ATmega32U4), SAMD boards: MIDIUSB library, no patch.
// Libraries: Adafruit NeoPixel (and MIDIUSB on the non-R4 boards).
// In relightCam: capture screen > interval menu > Dome. The board shows up in the dome row by itself.
// A USB serial port comes with it (115200 baud) and logs every LED change.
//
// On the R4 the USB-C port then belongs to the main chip, like with a USB keyboard sketch. To upload
// again, double-press RESET (the L LED pulses) and pick the port that appears.

#include <Adafruit_NeoPixel.h>

#if defined(ARDUINO_ARCH_RENESAS)
  #include "usb/USB.h"
  extern "C" {
    #include "tusb.h"
  }
  #if !CFG_TUD_MIDI
    #error "Patch the UNO R4 core first: python3 ../r4-usb-midi/patch_core.py (see the comment at the top)"
  #endif
  void __USBInstallMIDI() {}  // asks the patched core for a USB MIDI interface
  #define LOG SerialUSB
#else
  #include <MIDIUSB.h>
  #define LOG Serial
#endif

const int LED_PIN = 6;
const int NUM_LEDS = 24;  // LEDs on the strip (the current dome has 24)

Adafruit_NeoPixel strip(NUM_LEDS, LED_PIN, NEO_GRBW + NEO_KHZ800);

void allOff() {
  strip.clear();
  strip.show();
  LOG.println("all off");
}

void ledOn(byte n, byte velocity) {
  if (n >= NUM_LEDS) return;
  // one LED at a time: a photo must be lit by a single, known LED
  strip.clear();
  strip.setPixelColor(n, strip.Color(0, 0, 0, map(velocity, 1, 127, 2, 255)));  // white channel only
  strip.show();
  LOG.print("on ");
  LOG.print(n + 1);
  LOG.print(" (");
  LOG.print(velocity);
  LOG.println(")");
}

void ledOff(byte n) {
  if (n >= NUM_LEDS) return;
  strip.setPixelColor(n, 0);
  strip.show();
}

// Next USB-MIDI event (status, data1, data2); false when nothing arrived.
bool readMidi(byte &status, byte &d1, byte &d2) {
#if defined(ARDUINO_ARCH_RENESAS)
  uint8_t p[4];
  if (!tud_midi_available() || !tud_midi_packet_read(p)) return false;
  status = p[1]; d1 = p[2]; d2 = p[3];
  return true;
#else
  midiEventPacket_t rx = MidiUSB.read();
  if (rx.header == 0) return false;
  status = rx.byte1; d1 = rx.byte2; d2 = rx.byte3;
  return true;
#endif
}

void setup() {
#if defined(ARDUINO_ARCH_RENESAS)
  __USBStart();  // the R4 WiFi core doesn't start native USB by itself
#endif
  LOG.begin(115200);
  strip.begin();
  allOff();
}

void loop() {
  byte status, d1, d2;
  static unsigned long last = 0, lastSeen = 0;
  while (readMidi(status, d1, d2)) {
    lastSeen = millis();
    byte type = status & 0xF0;
    if (type == 0x90 && d2 > 0) ledOn(d1, d2);
    else if (type == 0x80 || type == 0x90) ledOff(d1);
    else if (type == 0xB0 && (d1 == 123 || d1 == 120)) allOff();
  }
  // while relightCam isn't talking to it, say so every 5 s
  if (millis() - last > 5000 && millis() - lastSeen > 5000) {
    last = millis();
    LOG.println("USB MIDI ready, waiting for relightCam");
  }
}
