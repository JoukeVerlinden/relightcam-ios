# Light dome over MIDI

relightCam can drive a light dome itself: during a capture it lights one LED, takes one photo,
turns the LED off and moves on to the next. It talks to the dome's microcontroller over **CoreMIDI**: an
Arduino wired to the iPhone that shows up as a class-compliant USB MIDI device (through USB-C, or a
Lightning to USB 3 Camera Adapter).

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
2. Keep it lit for the light time (default 200 ms; settable in steps of 10 ms up to 100 ms, then 50 ms up
   to 2 s). Even at 0–30 ms the photo stays correct, because step 3 still waits for a fully lit frame.
3. Wait for a camera frame whose exposure started after step 2 (frame timestamp ≥ now + exposure
   time), so the whole frame is lit by LED *n*. At most one photo is still being written at that
   point, so the camera never runs out of buffers.
4. Save that frame (a ≈12 MP JPEG) and record the LED number for it (`leds` in `project.json`).
5. Note Off *n*.

A run starts and ends with all LEDs off, and stops (all off) on Stop, when leaving the screen, or when
the camera stops delivering frames. With the default light time and 30 fps, one LED takes about
0.3–0.4 s, so the current 24-LED dome takes roughly 8–10 seconds.

On an iPhone (iJouke (2), real camera, simulated dome) the frame for each LED arrived 45–75 ms after
the light time, so a 24-LED run took 6.5 s. If the timestamps can't be compared, the third frame after the
light time is used instead. Debug builds print every dome event to the console.

Each photo records its LED number and gets that LED's direction from the dome's light positions (below),
so the sphere is optional.

## Light positions (.lp)

The dome's light positions come from a relight `.lp` file: line *n* of the list is LED *n*. The app ships
with the current UAntwerpen dome (24 LEDs, `RelightCam/Capture/DomeDefault.lp.txt`, rings at about 80°,
65°, 50° and 35° elevation, six LEDs each), and the dome settings can import another `.lp` (its number of
lights becomes the LED count) or go back to the default. With **Give photos these directions** on, every
dome photo gets its LED's direction as soon as it is saved, so the project can build an RTI without a
sphere; marking the sphere afterwards replaces them. The project screen says where its directions came
from, and the .lp export writes them out again.

The file's x and y axes must match the photos: x to the right of the photo, y to its top, z towards the
camera (relight's convention). If the phone is mounted rotated relative to the calibration, the directions
are rotated too.

## In the app

1. Capture screen › interval menu (bottom left) › **Dome**.
2. Connect the dome's Arduino with a USB cable; it appears in the dome row by itself. Tap the row to check
   the light positions, the number of LEDs (default 24), brightness and the light time before each photo.
3. The framing LED stays on while you frame: pinch to zoom, tap to focus (or switch the slider to focus
   with the ◎ button and set it by hand, e.g. while zoomed in), then **Lock**.
4. Press the red button. The run shows "LED *n* of *count*"; the red square stops it.

## Arduino UNO R4 WiFi + RGBW NeoPixels

[`../dome/relightcam_dome/relightcam_dome.ino`](../dome/relightcam_dome/relightcam_dome.ino) drives a
WS2812B-style RGBW strip (GRBW order) on pin 6, lights only the white channel, and logs every LED change
to its USB serial port at 115200 baud. Wired to the iPhone it appears as a USB MIDI device; the board
shows up in the app's dome row as soon as it is plugged in. An iPhone with
Lightning needs the Lightning to USB 3 Camera Adapter.

Out of the box the UNO R4 can be a USB keyboard but not a USB MIDI device: its core builds TinyUSB with
the MIDI class off (`CFG_TUD_MIDI 0`) and a fixed USB descriptor, and the MIDIUSB library doesn't support
the R4. [`../dome/r4-usb-midi/patch_core.py`](../dome/r4-usb-midi/patch_core.py) fixes that in the
installed "Arduino UNO R4 Boards" package: it switches the MIDI class on for the UNO R4 WiFi and adds a
MIDI interface to the USB descriptor, only for sketches that define `__USBInstallMIDI()`. Other sketches
build exactly as before. It keeps `.orig` backups (`--revert` restores them, `--check` reports), works
on macOS, Linux and Windows, and has to be re-run after updating the board package. Without it, the
sketch stops compiling with a message that says so.

Checked on an UNO R4 WiFi (core 1.6.0) connected to a Mac: it enumerates as a class-compliant USB MIDI
device "UNO R4 WiFi" in CoreMIDI, and a run through all 55 LEDs with the app's `DomeMIDI` code arrived
complete and in order. The same sketch builds for a Leonardo with the MIDIUSB library (no patch needed on
32U4 or SAMD boards).

As with a USB keyboard sketch, the R4's USB-C port then belongs to the main chip. To upload again,
double-press RESET (the L LED pulses) and pick the port that appears. On a Mac, allow the accessory if
macOS asks.

The usual NeoPixel advice applies: a separate 5 V supply for the strip, a common ground with the
Arduino, a 300–500 Ω resistor in the data line and a large capacitor across the strip's supply.

## Testing without a dome

- `tools/dome_test.swift` (macOS) runs the sequence against a virtual MIDI device and checks the
  order and timing of the messages (see the header for the command).
- Debug builds accept `-dome-autostart` (with `-open-capture`): the capture screen starts a Dome run
  after 4 s, and the dome log is printed to the console. With `-dome-virtual` this tests a full run on a
  phone without a dome: `xcrun devicectl device process launch --device <id> --console -- <bundle id>
  -autorun-textile -open-capture -dome-virtual -dome-autostart`.
- Debug builds accept the launch argument `-dome-virtual`: the app then creates a "Simulated dome"
  MIDI output that logs every message (`[dome] on LED 3 velocity 127`) to the console, so the dome
  screens can be tried in the simulator. iOS only allows such a virtual MIDI device with the audio
  background mode, which is why Debug builds use `Config/Info-Debug.plist`.
