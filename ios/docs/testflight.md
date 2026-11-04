# TestFlight test information

Texts entered in App Store Connect › relightCam › TestFlight. Keep them here so they're easy to update.

## Beta App Description

relightCam captures relightable images (RTIs) with an iPhone and explores them in 2D, on a simulated 3D cloth and in AR. Put the iPhone on a tripod with a shiny black sphere next to the object, and move a hand-held light between the photos. The app finds the light direction in every photo from the highlight on the sphere and builds a PTM or HSH relightable image, in the format of the relight toolkit (CNR-ISTI Visual Computing Lab). The 3D cloth viewer drapes the captured textile on a board, a dress form or free-hanging cloth, with live AR.

Developed at the University of Antwerp. No account needed. Everything is processed on the iPhone.

## What to Test

No sphere or setup at hand? Use a demo capture: on the home screen, tap the import button at the top right (the arrow into a tray), then Demo capture: silk textile. It runs the whole pipeline on a synthetic silk.

1. Capture: tripod, a shiny black sphere next to the object, a dark room, and a hand-held light moved between photos (30–60 photos). Or import photos.
2. Sphere and lights: mark the sphere and check that the light directions look right.
3. Build the RTI and open it in the 2D viewer. Drag or tilt the phone to move the light.
4. Open it in the 3D cloth viewer: try the board, the dress forms and free cloth, pin and drag the cloth, the Outline and Repeat editor (scissors), and AR.
5. Export an RTI, photos with a .lp file, or a 3D model.

Please report anything that's confusing, slow or wrong, with a screenshot if you can.

## Other fields

- Feedback email: jouke.verlinden@uantwerpen.be
- Privacy policy URL: https://github.com/JoukeVerlinden/relightcam-ios/blob/relightcam/ios/PRIVACY.md
- Sign-in required: no
