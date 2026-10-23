YT for TV
iPadOS 26+ · Swift 5.9 · MIT
Watch YouTube in its Leanback TV interface on your iPad — the same big-screen interface normally reserved for smart TVs — with a native D-pad remote control, swipe gestures, and a Liquid Glass UI built for iPadOS 26.

Screenshots
Add screenshots here — drag images into this section once the app is running on your iPad.

Features
* YouTube Leanback UI — loads youtube.com/tv with a webOS Smart TV user agent, unlocking the full big-screen interface
* D-pad remote control — on-screen panel with directional pad, OK, Back, Play/Pause, and Home
* Swipe navigation — swipe anywhere on the screen to send arrow key inputs
* Liquid Glass UI — remote panel uses iOS 26 glassEffect and GlassEffectContainer for a native feel
* Settings panel — toggle auto-hide on video playback, haptic feedback, reload, and home
* Native search — keyboard bridge routes iPad keyboard input directly to YouTube's search field
* Export IPA — built-in button to package and export the running app as a sideloadable .ipa file
* Display always on — keeps the screen awake during playback
* What's New sheet — version-gated onboarding screen on first launch

Requirements
* iPad running iPadOS 26 or later
* SideStore or any way to sideload IPA’s

Installation
1. Go to the Releases tab and install YT_for_TV.ipa in the latest release.
2. Open SideStore (or sideloading app) and sideload the app (mostly by going to the apps section and importing the IPA to install).
3. 3. 3. 3. Open the app YT for TV on your Home Screen and enjoy!

How It Works
YT for TV loads youtube.com/tv inside a WKWebView with a Samsung Smart TV user agent, which tricks YouTube into serving its Leanback interface instead of the standard mobile site.

The UI is split into two layers sitting above the web view:
* A 52×52pt trigger button pinned to the bottom-right corner — tap it to open the remote
* A full-screen panel that hosts the remote control, appearing only when the remote is open so taps pass through to the video underneath

The remote sends DOM keydown/keyup events directly to the web page via evaluateJavaScript. Search input uses a hidden UITextField whose text changes are injected into YouTube's search field in real time.

The Export IPA button uses a pure-Swift ZIP implementation to package Bundle.main.bundleURL into a Payload/structure, producing a valid .ipa file entirely on-device — no Mac, no Xcode, no command line needed.

License
MIT License — free to use, modify, and distribute.
Made by pixel-guys-projects · Built entirely on iPad with Swift Playgrounds
