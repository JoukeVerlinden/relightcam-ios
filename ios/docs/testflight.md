# TestFlight test information

Texts entered in App Store Connect › relightCam › TestFlight. Keep them here so they're easy to update.

## Beta App Description

relightCam captures relightable images (RTIs) with an iPhone and explores them in 2D, on a simulated 3D cloth and in AR. Put the iPhone on a tripod with a shiny black sphere next to the object, and move a hand-held light between the photos. The app finds the light direction in every photo from the highlight on the sphere and builds a PTM or HSH relightable image, in the format of the relight toolkit (CNR-ISTI Visual Computing Lab). The 3D cloth viewer drapes the captured textile on a board, a dress form or free-hanging cloth, with live AR.

Developed at the University of Antwerp. No account needed. Everything is processed on the iPhone.

## What to Test (version 1.1)

New: relightCam can drive a light dome. Connect the dome's Arduino (UNO R4 WiFi with the relightCam sketch, see github.com/JoukeVerlinden/relightcam-ios › ios/docs/dome-midi.md) to the iPhone with a USB cable; it shows up by itself as a USB MIDI device.
1. Start a capture and choose Dome in the interval menu (bottom left). The dome row should show the Arduino and 24 LEDs.
2. Frame the object with the framing LED on, pinch to zoom, tap to focus (or switch the slider to manual focus with ◎), then tap Lock.
3. Press the red button: the app lights each LED in turn and takes one photo per LED. The dome's light positions (built in, or import your own .lp in the dome settings) give every photo its light direction, so no sphere is needed. Tap Done and build the RTI.
4. In the dome settings, try the light time before each photo (from 10 ms) and the brightness.

Also new: pinch to zoom from the ultra wide to the telephoto, manual focus, and Import an RTI (import menu: a relight .zip or folder, PTM or HSH, e.g. exported from relightCam on another phone). Fixed: a crash when zooming onto the telephoto lens.

No dome? The hand-held light capture and the demo capture (import menu › Demo capture: silk textile) work as before. Please report anything confusing, slow or wrong, with a screenshot if you can.

## What to Test (version 1.0)

No sphere or setup at hand? Use a demo capture: on the home screen, tap the import button at the top right (the arrow into a tray), then Demo capture: silk textile. It runs the whole pipeline on a synthetic silk.

1. Capture: tripod, a shiny black sphere next to the object, a dark room, and a hand-held light moved between photos (30–60 photos). Or import photos.
2. Sphere and lights: mark the sphere and check that the light directions look right.
3. Build the RTI and open it in the 2D viewer. Drag or tilt the phone to move the light.
4. Open it in the 3D cloth viewer: try the board, the dress forms and free cloth, pin and drag the cloth, the Outline and Repeat editor (scissors), and AR.
5. Export an RTI, photos with a .lp file, or a 3D model.

Please report anything that's confusing, slow or wrong, with a screenshot if you can (take a screenshot on the iPhone and TestFlight offers to send it as feedback).

## Other fields

- Feedback email: jouke.verlinden@uantwerpen.be
- Privacy policy URL: https://github.com/JoukeVerlinden/relightcam-ios/blob/relightcam/ios/PRIVACY.md
- Sign-in required: no
- Review notes: no account needed, works offline; without a sphere and lamp, use the import button › Demo capture: silk textile, then open the project in both viewers. AR needs a floor or table in view.
- External group: Students (public link, open to anyone, no tester limit). First build submitted for Beta App Review on 4 November 2026.
