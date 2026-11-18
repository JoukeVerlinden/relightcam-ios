# Light dome over MIDI

relightCam can drive a light dome itself: during a capture it lights one LED, takes one photo,
turns the LED off and moves on to the next. It talks to the dome's microcontroller over **CoreMIDI**, so
any device that shows up as a MIDI output on the iPhone works: Bluetooth LE MIDI, or a class-compliant
USB MIDI device (through USB-C, or a Lightning to USB camera adapter).

## Protocol

| Message (channel 1) | Meaning |
|---|---|
| Note On, note *n*, velocity *v* | light LED *n* (LED 1 in the app is note 0); *v* = brightness, 1–127 |
| Note Off, note *n* | LED *n* off |
| Control Change 123 (All Notes Off) | all LEDs off |

The app also sends a Note Off for every LED when it turns everything off, so firmware that ignores
CC 123 still ends dark. It never lights two LEDs at once.

## Capture sequence

For each LED *n* from 0 to *count* − 1:

1. Note On *n*.
2. Wait the settle time (default 60 ms, settable 0–1000 ms).
3. Wait for a camera frame whose exposure started after step 2 (frame timestamp ≥ now + exposure
   time), so the whole frame is lit by LED *n*. At most one photo is still being written at that
   point, so the camera never runs out of buffers.
4. Save that frame (a ≈12 MP JPEG) and record the LED number for it (`leds` in `project.json`).
5. Note Off *n*.

A run starts and ends with all LEDs off, and stops (all off) on Stop, when leaving the screen, or when
the camera stops delivering frames. At 30 fps one LED takes about 0.15–0.25 s, so 55 LEDs take
roughly 10–15 seconds.

Light directions still come from the shiny sphere, exactly as with a hand-held light. Because every
frame records its LED, a later version can calibrate the dome once and reuse the directions.

## In the app

1. Capture screen › interval menu (bottom left) › **Dome**.
2. Tap the dome row › **Connect a Bluetooth MIDI device** and pick the dome (USB devices appear on
   their own). Set the number of LEDs, brightness and settle time; **Light each LED in turn** checks
   the wiring.
3. The framing LED stays on while you frame: tap to focus, then **Lock**.
4. Press the red button. The run shows "LED *n* of *count*"; the red square stops it.

## Arduino UNO R4 WiFi + RGBW NeoPixels

[`../dome/relightcam_dome/relightcam_dome.ino`](../dome/relightcam_dome/relightcam_dome.ino) is an
example for an UNO R4 WiFi with a WS2812B-style RGBW strip (GRBW order) on pin 6. It uses Bluetooth MIDI
through the board's ESP32-S3 module and lights only the white channel. It implements the BLE-MIDI
service itself with ArduinoBLE, so it needs only two libraries: Adafruit NeoPixel and ArduinoBLE. The
serial monitor (115200 baud) logs connections and every LED change. The usual NeoPixel advice applies: a separate 5 V supply for the strip, a common ground with
the Arduino, a 300–500 Ω resistor in the data line and a large capacitor across the strip's supply.

The sketch compiles for the UNO R4 WiFi (core 1.6.0, ArduinoBLE 2.1: 32 % of flash); its packet parser
was checked on a Mac with iOS-style packets (running status, several messages per packet, note 0). It
hasn't run with a strip yet. The BLE-MIDI library (lathoub) was dropped: its ArduinoBLE backend doesn't
compile without a workaround and reads the received bytes through a temporary string. If the board
doesn't show up in the app's Bluetooth list, update the R4 WiFi's ESP32 firmware (Arduino IDE › Tools ›
Firmware Updater); the sketch blinks the L LED and says so on the serial monitor when Bluetooth fails.

**Why not over the USB cable?** The UNO R4 can be a USB keyboard (HID) but not a USB MIDI device: its
core (1.6.0) builds TinyUSB with the MIDI class switched off (`CFG_TUD_MIDI 0`), the USB descriptor is
fixed in the core, and the MIDIUSB library doesn't support the R4. The cable can still power the board
from the phone; the MIDI goes over Bluetooth.

**Boards that can be wired:**
[`../dome/relightcam_dome_usb/relightcam_dome_usb.ino`](../dome/relightcam_dome_usb/relightcam_dome_usb.ino)
does the same over USB MIDI with the MIDIUSB library, for a Leonardo, Micro or Pro Micro (ATmega32U4) or
a SAMD board. It compiles for the Leonardo. The board appears in the app's dome row as soon as it is
plugged in, with no pairing. An iPhone with Lightning needs the Lightning to USB 3 Camera Adapter.

## Testing without a dome

- `tools/dome_test.swift` (macOS) runs the sequence against a virtual MIDI device and checks the
  order and timing of the messages (see the header for the command).
- Debug builds accept the launch argument `-dome-virtual`: the app then creates a "Simulated dome"
  MIDI output that logs every message (`[dome] on LED 3 velocity 127`) to the console, so the dome
  screens can be tried in the simulator. iOS only allows such a virtual MIDI device with the audio
  background mode, which is why Debug builds use `Config/Info-Debug.plist`.
