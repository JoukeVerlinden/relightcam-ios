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
- Version 1.1, build 2611181819 (1.0 / 2611042239 got a Guideline 2.1 information request; the version was renamed to 1.1 with the new build). Approved and released on 18 November 2026 (174 countries; China mainland excluded).
- Version 1.2, build 2611182322: the iOS 17 dress form icon fix, plus new screenshots and an App Preview made from the screen recording of the dome capture. Submitted 18 November 2026, set to release automatically after approval (to all users at once). On 19 November, while waiting for review, the description was rewritten: a short pitch, the open-source lineage (relight by CNR-ISTI's Visual Computing Lab, OpenLIME, PTM from HP Labs, HSH), a "What you need" section that makes clear the black sphere is only needed with a hand-held lamp, and the dome marked as still in development. Later that day, at the user's request, "How it works" was rewritten to lead with the dome and mention the black ball only once (for a hand-held lamp), the separate "What you need" section was dropped, and MIDI was taken out of What's New.

### What's New in 1.2

Fixed: on iOS 17 the dress form icon was missing in the 3D cloth viewer.

Also new since 1.1: relightCam can run a light dome over a USB cable, so dome captures need no black ball; pinch to zoom with manual focus; and import of RTIs made with relight.

## Version 1.3 (planned, after 1.2 is released)

Chosen on 19 November 2026: the new icon ships in 1.3 rather than swapping the build of 1.2, so 1.2 keeps its place in the review queue. 1.3 is the version in the project (MARKETING_VERSION). It carries:
- the new app icon (tools/make_icon.swift): two rings of dome LEDs from 60 pt up, one ring below, with dark and tinted versions;
- no cut-off labels in the 2D and cloth viewers on narrow screens (375 pt iPhones, the iPhone Duo's outer screen);
- the light dome in plain words in the app (no MIDI terms).
The user wants feedback on these before pushing them to GitHub. To ship: create version 1.3 in App Store Connect once 1.2 is live, upload a build through Xcode Organizer, add the iPhone Duo screenshot ("relightCam App Store screenshots/iPhone Duo") if the Duo slot takes it, attach the build and submit. Description, screenshots and preview carry over from 1.2.

### What's New in 1.3 (draft)

A new icon: the light dome seen from above, one LED raking a gold lampas motif.

Easier to read on small and folding iPhones: the viewer controls no longer cut labels short on narrower screens, and the light dome settings use plain words.

### Promotional text

Capture an object under a moving light and relight it on your iPhone: in 2D, draped on a simulated 3D cloth, or in AR in your own room.

### Description

Move the light over a textile with your finger: relightCam captures relightable images (RTI) with an iPhone and shows the weave, the sheen of silk and the relief of embroidery under any light, in 2D, draped on a 3D dress form, or in AR.

relightCam builds on proven open-source research instead of reinventing it. RTI is an established method for documenting cultural heritage. The app's processing follows relight, the open-source RTI toolkit of the Visual Computing Lab at CNR-ISTI in Pisa, and writes relight's open web format, so results open in the OpenLIME web viewer and in RelightLab. It fits polynomial texture maps (PTM, first published by HP Labs in 2001) or hemispherical harmonics (HSH). relightCam was developed and tested at the University of Antwerp, with students and real textiles, and is open source itself.

WHY
A single photo hides most of what makes a textile special: the weave, the sheen of silk, gold threads and the relief of embroidery only show when the light moves. An RTI records how a surface reflects light from every direction, so you can relight it afterwards, as often as you like. This usually takes a light dome or a camera rig, a computer and specialist software. relightCam does it all on the phone, so you can capture an object where it is: in a museum store, a classroom or a studio.

WHO IT'S FOR
• Students and teachers in design, fashion, textiles and heritage
• Conservators, curators and collection managers who document textiles
• Designers and makers who want to show how a fabric looks and drapes
It works for any flat object too, such as coins, clay tablets, paintings, leather or paper.

HOW IT WORKS
1. Capture. Put the iPhone on a tripod in a dark room and take 30 to 60 photos, each lit from another direction. With a light dome, relightCam does the lighting itself: connect the dome with a USB cable, and it lights one LED after the other and takes a photo for each. Without a dome, move a lamp by hand between the photos while an interval timer takes them; a small glossy black ball beside the object then shows the app where the light came from. Focus, exposure and white balance stay locked. You can also import photos, or try the built-in demo.
2. Process. relightCam works out the light direction of every photo and computes the relightable image (PTM or HSH) right on the phone.
3. View. In the 2D viewer, drag, or tilt the phone, to move the light, with RTI, specular, shaded and normal-map modes. The 3D cloth viewer drapes the textile on a board, on historical dress forms (1770s panniers, 1860s crinoline, 1880s bustle, 1920s) or as free-hanging cloth, with silk, linen, wool and tapestry presets, bias cut, pins and tiling of a pattern repeat. In live AR, the simulated cloth hangs in your room with real gravity, lit from the phone itself, and you can walk around it.
4. Share. Export an RTI with a web viewer (OpenLIME), the photos with a light file for RelightLab, or a 3D model (USDZ). RTIs in relight's web format can be imported too.

BUILD YOUR OWN DOME
A dome makes captures faster and easier to repeat. The University of Antwerp is developing an open-source light dome that you can build yourself, with laser-cut parts, an Arduino and affordable electronics. It is still in development: the Arduino code is already in the relightCam repository on GitHub, and the designs will follow.

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

From 1.2 the iPhone set (10) leads with seven frames from the screen recording of a real dome capture (embroidered textile, 24-LED UAntwerpen dome): dress form, 2D viewer under raking light, Dome capture at "LED 14 of 24", the Light dome settings, the project with "24 of 24 usable", the specular view and free cloth. These are followed by the earlier AR, sphere and pattern-editor shots. The recording's status bar (16:28, red recording pill) was replaced with the 09:41 bar of the earlier set, and the green camera dot removed. Frames are 1206 × 2622 (6.3"), scaled to 1320 × 2868 for the 6.9" slot. Drop 6.9" files on the large-display box: the 6.3" box rejects them.

App Preview (1.2): 28 s from the 2D viewer part of the recording (light moving in RTI mode, then specular), 886 × 1920, 30 fps, H.264 High 4.0 at 11 Mbit/s, silent stereo AAC 256 kbit/s. App Previews must be screen recordings of the app, so the hardware footage can't be used; GIFs aren't accepted.

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
