# YT for TV

![iPadOS](https://img.shields.io/badge/iPadOS-26%2B-blue?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5.9-orange?logo=swift)
![Version](https://img.shields.io/badge/version-2.0-red)
![License](https://img.shields.io/badge/license-Apache--2.0-blue)

Watch YouTube in its **Leanback TV interface** on your iPad. It's the same big-screen interface normally reserved for smart TVs, with an on-screen remote, swipe navigation, and a Liquid Glass UI built for iPadOS 26.

## Features

- **YouTube Leanback UI**: loads `youtube.com/tv` with a Samsung Smart TV user agent to unlock the full big-screen interface.
- **On-screen remote**: a floating glass button opens a remote with a D-pad, OK, Back, Play/Pause (the icon and label switch with playback), and Home.
- **Swipe navigation**: swipe to move around the interface. Swipe down during a video to go back.
- **Liquid Glass UI**: every control uses interactive glass, with red accents on the main actions.
- **Button sounds**: iPads have no Taptic Engine, so presses play a short click, a little different each time. iPhones use haptics. You can turn this off in Settings.
- **Landscape only**: portrait shows a reminder until you rotate the device.
- **Offline screen**: a friendly message appears when the connection drops, and the app reloads when it returns.
- **Settings panel**: reload, go home, auto-hide the remote during video playback, sound or haptic feedback, About App, and Export IPA.
- **About panel**: version, build number, copyright, and a shortcut to What's New.
- **What's New**: a one-time overview of each release's features on first launch.
- **Export IPA**: packages the app as a sideloadable `.ipa` from the Settings panel.
- **Display always on**: the screen stays awake during playback.

## Screenshots

> Add screenshots here: drag images into this section once the app is running on your iPad.

## Requirements

- An **iPad** running **iPadOS 26** or later
- **SideStore**, or any other way to sideload IPAs

## Installation

1. Go to the **Releases** tab and download `YT_for_TV.ipa` from the latest release.
2. Open SideStore (or your sideloading app), go to the Apps section, and import the IPA to install it.
3. Open **YT for TV** from your Home Screen and enjoy!

## How It Works

YT for TV loads `youtube.com/tv` in a `WKWebView` with a Samsung Smart TV user agent, which tricks YouTube into serving its Leanback interface instead of the standard mobile site.

The app is layered above the web view:

- A **56×56pt trigger button** in the bottom-right corner opens the remote.
- The **remote panel** appears only when open, so taps elsewhere reach the video underneath.

Remote presses are sent to the page as DOM `keydown` and `keyup` events through `evaluateJavaScript`. Swipes are converted to arrow keys.

The **Export IPA** button uses a pure-Swift ZIP implementation to package `Bundle.main.bundleURL` into a `Payload/` folder and writes the `Info.plist` for the exported build. It runs entirely on-device, so no Mac, Xcode, or command line is needed.

## License

Licensed under the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0). See the `LICENSE` file for details.

---

Made by [Hylance](https://github.com/pixel-guys-projects) · Built entirely on iPad with Swift Playgrounds
