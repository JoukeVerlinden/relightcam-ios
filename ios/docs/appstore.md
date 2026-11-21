# App Store listing

Texts and settings entered in App Store Connect › relightCam (app 6830881665). Keep them here so they're easy to update.

## App Information

- Name: relightCam
- Subtitle: Relightable images of textiles
- Primary category: Photo & Video. Secondary: Education
- Content rights: no third-party content
- Age rating: 4+ (every questionnaire item answered None or No, including Shared Location and Dating and Relationships, which Apple added in late 2026; answered 19 November 2026)
- Copyright: 2026 University of Antwerp

## Pricing and availability

Free ($0.00, base country United States), available in all 175 countries and regions. Public distribution, iPhone and iPad only: Mac (Designed for iPad) and Apple Vision Pro availability were switched off on 19 November 2026, because neither has a camera to capture with.

## App Accessibility

Published on 19 November 2026 for iPhone and iPad: Dark Interface only (checked in the simulator: lists and settings follow the system's dark mode; the viewers and capture screen are always dark). Not claimed yet: VoiceOver, Voice Control, Larger Text, Differentiate Without Color Alone, Sufficient Contrast, Reduced Motion; Captions and Audio Descriptions don't apply. The app has only a handful of accessibility labels, a few fixed text sizes and no Reduce Motion handling, so an accessibility pass comes once the features settle. Published support can be extended later but not unpublished.

## App Privacy

Data Not Collected, published on 7 November 2026. Privacy policy URL: https://github.com/JoukeVerlinden/relightcam-ios/blob/relightcam/ios/PRIVACY.md. The app has no accounts, no analytics and no network access (see [PRIVACY.md](../PRIVACY.md)).

## Version 1.0

- Release: manual, after App Review approval
- Version 1.1, build 2611181819 (1.0 / 2611042239 got a Guideline 2.1 information request; the version was renamed to 1.1 with the new build). Approved and released on 18 November 2026 (174 countries; China mainland excluded).
- Version 1.2, build 2611182322 (withdrawn from review on 21 November 2026 and renamed 1.3, see below): the iOS 17 dress form icon fix, plus new screenshots and an App Preview made from the screen recording of the dome capture. Submitted 18 November 2026, set to release automatically after approval (to all users at once). On 19 November, while waiting for review, the description was rewritten: a short pitch, the open-source lineage (relight by CNR-ISTI's Visual Computing Lab, OpenLIME, PTM from HP Labs, HSH), a "What you need" section that makes clear the black sphere is only needed with a hand-held lamp, and the dome marked as still in development. Later that day, at the user's request, "How it works" was rewritten to lead with the dome and mention the black ball only once (for a hand-held lamp), the separate "What you need" section was dropped, and MIDI was taken out of What's New.

### What's New in 1.2

Fixed: on iOS 17 the dress form icon was missing in the 3D cloth viewer.

Also new since 1.1: relightCam can run a light dome over a USB cable, so dome captures need no black ball; pinch to zoom with manual focus; and import of RTIs made with relight.

## Version 1.3

1.2 waited for review from 18 to 21 November 2026 without being picked up. On 21 November the user had it removed from review (Developer Rejected), the version renamed to 1.3 and build 2611211725 attached, which carries:
- the new app icon (tools/make_icon.swift): two rings of dome LEDs from 60 pt up, one ring below, with dark and tinted versions;
- no cut-off labels in the 2D and cloth viewers on narrow screens (375 pt iPhones, the iPhone Duo's outer screen);
- the light dome in plain words in the app (no MIDI terms);
- everything that was in 1.2 (the iOS 17 icon fix).
Description, screenshots, App Preview, review notes and automatic release carried over from 1.2. The iPhone Duo slot takes 2853 × 2007 (unfolded) or 1398 × 2034 (folded) screenshots; ours is in "relightCam App Store screenshots/iPhone Duo".

### What's New in 1.3

A new icon: the light dome seen from above, one LED raking a gold lampas motif.

Easier to read on small and folding iPhones: the viewer controls no longer cut labels short on narrower screens, and the light dome settings use plain words.

Fixed: on iOS 17 the dress form icon was missing in the 3D cloth viewer.

Also new since 1.1: relightCam can run a light dome over a USB cable, so dome captures need no black ball; pinch to zoom with manual focus; and import of RTIs made with relight.

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
