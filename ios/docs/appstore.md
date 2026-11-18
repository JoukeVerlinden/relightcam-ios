# App Store listing

Texts and settings entered in App Store Connect › relightCam (app 6830881665). Keep them here so they're easy to update.

## App Information

- Name: relightCam
- Subtitle: Relightable images of textiles
- Primary category: Photo & Video. Secondary: Education
- Content rights: no third-party content
- Age rating: 4+ (every questionnaire item answered None or No)
- Copyright: 2026 University of Antwerp

## Pricing and availability

Free ($0.00, base country United States), available in all 175 countries and regions. Public distribution; also offered on Apple silicon Macs and Apple Vision Pro (the defaults).

## App Privacy

Data Not Collected, published on 7 November 2026. Privacy policy URL: https://github.com/JoukeVerlinden/relightcam-ios/blob/relightcam/ios/PRIVACY.md. The app has no accounts, no analytics and no network access (see [PRIVACY.md](../PRIVACY.md)).

## Version 1.0

- Release: manual, after App Review approval
- Build: 2611042239

### Promotional text

Capture an object under a moving light and relight it on your iPhone: in 2D, draped on a simulated 3D cloth, or in AR in your own room.

### Description

relightCam captures relightable images (RTI, reflectance transformation imaging) with nothing more than an iPhone, a shiny black sphere and a lamp, and lets you explore them under any light.

WHY
A single photo hides most of what makes a textile special: the weave, the sheen of silk, gold threads and the relief of embroidery only show when the light moves. An RTI records how a surface reflects light from every direction, so you can relight it afterwards, as often as you like. This usually takes a light dome or a camera rig, a computer and specialist software. relightCam does it all on the phone, so you can capture an object where it is: in a museum store, a classroom or a studio.

WHO IT'S FOR
• Students and teachers in design, fashion, textiles and heritage
• Conservators, curators and collection managers who document textiles
• Designers and makers who want to show how a fabric looks and drapes
It works for any flat object too, such as coins, clay tablets, paintings, leather or paper.

HOW IT WORKS
1. Capture. Put the iPhone on a tripod with a shiny black sphere next to the object. In a dark room, take 30 to 60 photos and move a hand-held light to a new spot between them. Focus, exposure and white balance are locked, and an interval timer takes the photos. A light dome works too: mount the iPhone above the object, keep the sphere in view, and let the dome switch its LEDs on one by one in step with the timer. Or import photos from Photos or Files, for example from a dome with its own camera. No setup at hand? Try the demo capture of a silk lampas.
2. Process. The app finds the light direction in every photo from the highlight on the sphere, and fits a PTM or HSH relightable image, in the open format of the relight toolkit by the CNR-ISTI Visual Computing Lab. Enter the sphere's diameter to give the image its real size.
3. View. In the 2D viewer, drag, or tilt the phone, to move the light, with RTI, specular, shaded and normal-map modes. The 3D cloth viewer drapes the captured textile on a board, on historical dress forms (1770s panniers, 1860s crinoline, 1880s bustle, 1920s) or as free-hanging cloth, with silk, linen, wool and tapestry presets, bias cut, pins and tiling of a pattern repeat. In live AR, the simulated cloth hangs in your room with real gravity, lit from the phone itself, and you can walk around it.
4. Export. Share an RTI with a web viewer (OpenLIME), the photos with a .lp light file for RelightLab, or a 3D model (USDZ).

BUILD YOUR OWN DOME
A dome makes captures faster and easier to repeat. The University of Antwerp is developing an open-source light dome that you can build yourself, with laser-cut parts, an Arduino and affordable electronics. Its designs will be shared in the relightCam repository on GitHub (link below).

Everything runs on the iPhone: no account, no tracking, no internet connection needed.

Developed at the University of Antwerp. Open source (GPL-3.0): github.com/JoukeVerlinden/relightcam-ios

### Keywords

RTI,PTM,HSH,relight,textile,fabric,heritage,museum,conservation,cloth,drape,AR,reflectance

### URLs

- Support URL: https://github.com/JoukeVerlinden/relightcam-ios/issues
- Marketing URL: https://github.com/JoukeVerlinden/relightcam-ios

### App Review information

- Sign-in required: no
- Contact: same as for TestFlight
- Notes: No account or sign-in is needed. The app works offline; it has no server. Without a sphere and lamp at hand, use the import button at the top right of the home screen, then "Demo capture: silk textile": it runs the whole pipeline (light detection, RTI build) on a synthetic silk sample. Then open the project and try "Open relightable image" and "Open in 3D cloth viewer". AR needs a floor or table in view.

### Screenshots

Made in the iPhone 17 Pro Max (6.9", 1320 × 2868) and iPad Pro 13" (2064 × 2752) simulators with the demo capture, plus one AR frame recorded on an iPhone 13 Pro.

Upload screenshots to the Asset Library, then pick them per size in the version's Media Manager (Browse Assets; the click order sets the order). The 6.9" set sits in the "iPhone with Dynamic Island, large display" slot, and the required 6.3" slot reuses it automatically ("Using Existing Assets"). The iPad set sits in the required iPad 13" slot.


## App Review: Guideline 2.1, Information Needed (18 November 2026)

App Review asked for a screen recording on a physical device (starting with the app's launch) and these
answers in the Notes field of App Review Information. The recording goes in the Attachment field.

```
1. Screen recording: attached. It was made on an iPhone with the latest iOS and starts with launching the app. It shows the demo capture, light detection, the RTI build, the 2D viewer, the 3D cloth viewer and AR, the camera capture screen and an export. relightCam has no accounts, no user-generated content shared with others, and no paid content.

2. Purpose and audience: relightCam makes relightable images (RTI, reflectance transformation imaging) of textiles and other flat objects with an iPhone. A single photo can't show the weave, the sheen of silk or the relief of embroidery; an RTI records how the surface reflects light from every direction, so it can be relit afterwards. RTI normally needs a light dome or camera rig, a computer and specialist software; relightCam does the capture, the processing and the viewing on the phone. It is developed at the University of Antwerp for students and teachers in design, fashion, textiles and heritage, and for conservators and curators who document textiles.

3. How to try it (no login, no equipment, no files needed): on the home screen, tap the import button at the top right (the arrow into a tray) and choose "Demo capture: silk textile". The app generates a synthetic capture: 34 photos of a silk sample with a black sphere. In the project, tap "Mark sphere & detect lights" and "Detect lights", then "Build RTI", then "Open relightable image" (drag, or tilt the phone, to move the light) and "Open in 3D cloth viewer" (board, dress forms or free cloth; AR needs a floor or table in view). With real equipment, the camera button opens the capture screen: tripod, a shiny black sphere next to the object, and a hand-held light moved between the photos on an interval timer. Optional: a light dome driven by an Arduino over a USB cable (USB MIDI) can light the object LED by LED; it is an extra for labs and isn't needed to review the app.

4. External services: none. The app has no server and no network access, and no accounts, analytics, advertising, payments or AI services. Everything runs on the device with Apple frameworks (AVFoundation, Metal, ARKit and RealityKit, Vision, Core Motion, PhotosUI, Core MIDI). Exports go only where the user sends them with the share sheet; the exported web viewer is OpenLIME, an open-source viewer bundled in the app.

5. Regions: the app works the same in all regions; there are no regional differences in features or content. It is in English.

6. Not a regulated industry, and no protected third-party material: the demo capture is generated by the app itself. Open-source components (the relight algorithms, reimplemented in Swift, and the OpenLIME viewer) are credited with their licenses under How it works › Credits and licenses.
```

For a 1.0 build, leave out the light dome sentence and "Core MIDI" (1.0 has no dome support).
