// YT for TV — Swift Playgrounds Edition  |  Requires iPadOS 26+

import SwiftUI
import UIKit
import WebKit
import Network
import AVFoundation

// ─────────────────────────────────────────────────────────────
// MARK: – Remote keys
// ─────────────────────────────────────────────────────────────

enum RemoteKey {
    case up, down, left, right, select, back, playPause
    
    var keyCode: Int {
        switch self {
        case .up:        return 38
        case .down:      return 40
        case .left:      return 37
        case .right:     return 39
        case .select:    return 13
        case .back:      return 27
        case .playPause: return 32
        }
    }
    
    var key: String {
        switch self {
        case .up:        return "ArrowUp"
        case .down:      return "ArrowDown"
        case .left:      return "ArrowLeft"
        case .right:     return "ArrowRight"
        case .select:    return "Enter"
        case .back:      return "Escape"
        case .playPause: return " "
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – Navigation delegate (allows all loads so icons render)
// ─────────────────────────────────────────────────────────────

private final class AllowAllNavigationDelegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – Web model
// ─────────────────────────────────────────────────────────────

private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WebModel?
    init(_ t: WebModel) { target = t }
    func userContentController(_ c: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.handle(message)
    }
}

final class WebModel: ObservableObject {
    static let homeURL   = URL(string: "https://www.youtube.com/tv")!
    static let userAgent = "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0) " +
    "AppleWebKit/538.1 (KHTML, like Gecko) " +
    "Version/6.0 TV Safari/538.1"
    
    @Published var showRemote      = false
    @Published var isVideoPlaying  = false
    
    let webView: WKWebView
    private let navDelegate = AllowAllNavigationDelegate()
    
    /// Every 800 ms reports whether a video is playing.
    private static let pollingJS = #"""
    setInterval(function () {
        var v = document.querySelector('video');
        var playing = !!(v && !v.paused && !v.ended && v.readyState > 2);
        try { window.webkit.messageHandlers.yt4tv.postMessage({ playing: playing }); }
        catch (_) {}
    }, 800);
    """#
    
    init() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = .default()
        
        let webPrefs = WKWebpagePreferences()
        webPrefs.allowsContentJavaScript = true
        cfg.defaultWebpagePreferences = webPrefs
        
        cfg.userContentController.addUserScript(
            WKUserScript(source: Self.pollingJS,
                         injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true)
        )
        
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.customUserAgent = Self.userAgent
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.navigationDelegate = navDelegate
        
        cfg.userContentController.add(WeakHandler(self), name: "yt4tv")
        load(Self.homeURL)
    }
    
    func handle(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let playing = body["playing"] as? Bool ?? false
        if isVideoPlaying != playing { isVideoPlaying = playing }
    }
    
    func press(_ key: RemoteKey) {
        let js = """
        (function () {
            var t = document.activeElement || document.body;
            var o = { key: '\(key.key)', keyCode: \(key.keyCode),
                      which: \(key.keyCode), bubbles: true, cancelable: true };
            t.dispatchEvent(new KeyboardEvent('keydown', o));
            t.dispatchEvent(new KeyboardEvent('keyup',   o));
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
    
    func reload() {
        if webView.url == nil {
            load(Self.homeURL)
        } else {
            _ = webView.reload()
        }
    }
    
    func goHome() { load(Self.homeURL) }
    
    private func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – Web view + swipe gestures
// ─────────────────────────────────────────────────────────────

struct WebContainer: UIViewRepresentable {
    let model: WebModel
    
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    
    func makeUIView(context: Context) -> WKWebView {
        let web = model.webView
        for dir: UISwipeGestureRecognizer.Direction in [.up, .down, .left, .right] {
            let g = UISwipeGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.swiped(_:)))
            g.direction = dir
            g.delegate  = context.coordinator
            web.addGestureRecognizer(g)
        }
        return web
    }
    
    func updateUIView(_ view: WKWebView, context: Context) {}
    
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let model: WebModel
        init(model: WebModel) { self.model = model }
        
        @objc func swiped(_ g: UISwipeGestureRecognizer) {
            Haptics.impact(.light)
            switch g.direction {
            case .right: model.press(.left)
            case .left:  model.press(.right)
            case .up:    model.press(.down)
            default:     model.press(model.isVideoPlaying ? .back : .up)
            }
        }
        
        func gestureRecognizer(
            _ g: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – Remote button (glass, labeled, full hit-target)
// ─────────────────────────────────────────────────────────────

/// Haptics respect the "Haptic feedback" toggle in Settings (on by default).
/// iPads have no Taptic Engine, so they get a short synthesized click instead.
final class SoundFeedback {
    static let shared = SoundFeedback()
    
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var configured = false
    
    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }
    
    func prepare() {
        if !configured {
            // .ambient + mixWithOthers: never interrupts YouTube's audio.
            try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            configured = true
        }
        if !engine.isRunning { try? engine.start() }
        if engine.isRunning && !player.isPlaying { player.play() }
    }
    
    /// intensity 0...1 — louder and higher-pitched as it grows.
    func tick(intensity: Float) {
        prepare()
        guard engine.isRunning else { return }
        let rate   = format.sampleRate
        let frames = AVAudioFrameCount(rate * 0.04)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        let freq = 500.0 + 900.0 * Double(intensity)
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            samples[i] = Float(sin(2 * Double.pi * freq * t) * exp(-t * 80)) * intensity
        }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }
}

/// Feedback respects the toggle in Settings (on by default):
/// a haptic on devices that have a Taptic Engine, a short click on iPad.
enum Haptics {
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true
    }
    
    static var usesSound: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    
    static func prepare() {
        if usesSound { SoundFeedback.shared.prepare() }
    }
    
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard enabled else { return }
        if usesSound {
            let base: Float
            switch style {
            case .light:  base = 0.35
            case .medium: base = 0.55
            case .rigid:  base = 0.85
            default:      base = 0.5
            }
            // A little random variation so no two presses sound identical.
            let jitter = Float.random(in: -0.12...0.12)
            SoundFeedback.shared.tick(intensity: min(max(base + jitter, 0.15), 1))
        } else {
            UIImpactFeedbackGenerator(style: style).impactOccurred()
        }
    }
}

/// Plain button style that fires a haptic the moment the button is pressed down.
struct HapticButtonStyle: ButtonStyle {
    let feedback: UIImpactFeedbackGenerator.FeedbackStyle
    
    init(_ feedback: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        self.feedback = feedback
    }
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.impact(feedback) }
            }
    }
}

struct RBtn: View {
    let icon: String
    var label: String? = nil
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                if let label {
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 56)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(HapticButtonStyle(.rigid))
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – Remote panel
// ─────────────────────────────────────────────────────────────

struct RemoteView: View {
    @EnvironmentObject private var model: WebModel
    @EnvironmentObject private var updates: UpdateChecker
    /// In Laptop mode the remote lives in the lower half and can't be dismissed.
    var alwaysOpen = false
    @AppStorage("autoHideOnVideo") private var autoHideOnVideo = true
    @AppStorage("hapticsEnabled")  private var hapticsEnabled  = true
    @State private var showSettings = false
    @State private var showAbout    = false
    
    var body: some View {
        VStack(spacing: 12) {
            header
            Divider().opacity(0.3)
            if showSettings { settingsBody } else { dpadBody }
        }
        .padding(16)
        .frame(width: 260)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .sheet(isPresented: $showAbout) { AboutView() }
    }
    
    // MARK: Header
    
    private var header: some View {
        HStack(spacing: 8) {
            Text(showSettings ? "Settings" : "Remote")
                .font(.headline)
            Spacer()
            // Settings toggle
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showSettings.toggle()
                }
            } label: {
                Image(systemName: showSettings ? "av.remote" : "gearshape")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(HapticButtonStyle())
            .glassEffect(.regular.interactive(), in: Circle())
        }
    }
    
    // MARK: D-pad
    
    private var dpadBody: some View {
        VStack(spacing: 6) {
            // Up
            HStack {
                Spacer()
                RBtn(icon: "chevron.up") { model.press(.up) }
                Spacer()
            }
            // Left / OK / Right
            HStack(spacing: 6) {
                RBtn(icon: "chevron.left") { model.press(.left) }
                RBtn(icon: "checkmark") { model.press(.select) }
                RBtn(icon: "chevron.right") { model.press(.right) }
            }
            // Down
            HStack {
                Spacer()
                RBtn(icon: "chevron.down") { model.press(.down) }
                Spacer()
            }
            
            Divider().opacity(0.3)
            
            // Action row
            HStack(spacing: 6) {
                RBtn(icon: "arrow.uturn.backward", label: "Back")   { model.press(.back) }
                RBtn(icon: model.isVideoPlaying ? "pause.fill" : "play.fill",
                     label: model.isVideoPlaying ? "Pause" : "Play") { model.press(.playPause) }
                RBtn(icon: "house.fill",            label: "Home")   { model.goHome() }
            }
            
            // Close — bottom-right
            if !alwaysOpen { HStack {
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        model.showRemote = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(HapticButtonStyle())
                .glassEffect(.regular.interactive(), in: Circle())
            } }
        }
    }
    
    // MARK: Settings
    
    private var settingsBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("PLAYBACK")
            settingsRow("Reload Page",  icon: "arrow.clockwise") { model.reload() }
            settingsRow("Go to Home",   icon: "house")            { model.goHome() }
            
            sectionLabel("PREFERENCES")
            VStack(spacing: 6) {
                Toggle("Auto-hide on video", isOn: $autoHideOnVideo)
                Toggle(Haptics.usesSound ? "Button sounds" : "Haptic feedback",
                       isOn: $hapticsEnabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            
            sectionLabel("ABOUT")
            settingsRow("About App", icon: "info.circle") { showAbout = true }
            settingsRow("Check for Updates", icon: "arrow.down.circle") { updates.check(manual: true) }
            Link(destination: URL(string: "https://us.wps.com/forms/g/yFG5SfkL/")!) {
                Label("Send Feedback", systemImage: "envelope")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(HapticButtonStyle())
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            
            sectionLabel("EXPORT")
            ExportIPAButton()
                .frame(maxWidth: .infinity)
        }
    }
    
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
    
    private func settingsRow(_ title: String,
                             icon: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(HapticButtonStyle())
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – Trigger button
// ─────────────────────────────────────────────────────────────

struct TriggerButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: "av.remote.fill")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(HapticButtonStyle())
        .glassEffect(.regular.interactive(), in: Circle())
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – Network monitor
// ─────────────────────────────────────────────────────────────

final class NetworkMonitor: ObservableObject {
    @Published private(set) var isConnected = true
    private let monitor = NWPathMonitor()
    
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.isConnected = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "yt4tv.network"))
    }
    deinit { monitor.cancel() }
}

/// Shown whenever the device is in portrait orientation.
struct PortraitWarningView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                if let img = UIImage(named: "onportrait") {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220)
                } else {
                    Image(systemName: "rectangle.portrait.slash")
                        .font(.system(size: 72, weight: .thin))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Text("We don't accept portrait.")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }
}

struct NoInternetView: View {
    @EnvironmentObject private var model: WebModel
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                if let img = UIImage(named: "nointernet") {
                    Image(uiImage: img)
                        .resizable().scaledToFit().frame(maxWidth: 280)
                } else {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 72, weight: .thin))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Text("Oh shoot, where's the internet.")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Text("Check your connection and try again.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                Button {
                    model.reload()
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .contentShape(Capsule())
                }
                .buttonStyle(HapticButtonStyle())
                .glassEffect(.regular.interactive(), in: Capsule())
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – What's New
// ─────────────────────────────────────────────────────────────

private let currentVersion = "2.1"
/// Bump this when the What's New content changes so it shows again once.
private let whatsNewRevision = "2.1-r1"

/// Full-screen about sheet.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showWhatsNew = false
    
    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────
            VStack(spacing: 14) {
                if let icon = UIImage(named: "icon") {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 110, height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(radius: 8)
                } else {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.red.gradient)
                        .frame(width: 110, height: 110)
                        .overlay {
                            Image(systemName: "tv.fill")
                                .font(.system(size: 42))
                                .foregroundStyle(.white)
                        }
                }
                Text("YT for TV")
                    .font(.largeTitle.bold())
                Text("Version 2.1")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 52)
            .padding(.bottom, 32)
            
            // ── Actions ─────────────────────────────────────────
            VStack(spacing: 12) {
                Button {
                    showWhatsNew = true
                } label: {
                    Label("What's New in v2", systemImage: "sparkles")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .contentShape(Capsule())
                }
                .buttonStyle(HapticButtonStyle())
                .glassEffect(.regular.tint(.red).interactive(), in: Capsule())
                .padding(.horizontal, 32)
            }
            
            Spacer()
            
            // ── Copyright ────────────────────────────────────────
            VStack(spacing: 4) {
                Text("YouTube for TV")
                    .font(.footnote.weight(.semibold))
                Text("Version 2.1 build imp15c")
                Text("All Rights Reserved.")
                Text("Made by Hylance.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.bottom, 44)
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView(isPresented: $showWhatsNew)
                .tint(.red)
        }
    }
}


struct WhatsNewView: View {
    @Binding var isPresented: Bool
    
    private let features: [(String, String, String)] = [
        ("sparkles.tv.fill",        "YouTube TV Interface",
         "The full big-screen Leanback experience, right on your iPad."),
        ("av.remote.fill",          "On-screen Remote",
         "D-pad, OK, Back, Play/Pause and Home. Tap anywhere outside the remote to use YouTube directly."),
        ("hand.draw.fill",          "Swipe Navigation",
         "Swipe to move around the interface. Swipe down during a video to go back."),
        ("speaker.wave.2.fill",     "Button Sounds",
         "iPads have no Taptic Engine, so presses play a short click, a little different each time. iPhones keep haptics."),
        ("iphone.gen3.slash",       "Landscape Only",
         "Rotate to landscape to use the app. Portrait shows a reminder until you turn the device."),
        ("info.circle.fill",        "About Panel",
         "Find the version, build number and copyright under About App in Settings."),
        ("wifi.slash",              "Offline Screen",
         "A friendly message appears when you lose internet, and the app reloads when it returns."),
        ("square.and.arrow.up",     "Export IPA",
         "Package the app as a sideloadable IPA from the Settings panel."),
        ("ipad.and.iphone",         "Foldable iPhone Support",
         "Use Open, Laptop, or Tent mode. In Laptop mode the video sits on top and the remote below."),
        ("arrow.down.circle.fill",  "Update Checker",
         "The app checks for new versions and tells you when one is ready."),
        ("envelope.fill",           "Send Feedback",
         "Tell us what you think from the About section in Settings."),
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "sparkles.tv.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.red)
                    .padding(.top, 48)
                Text("What's New in YT for TV")
                    .font(.largeTitle.bold())
                Text("Version \(currentVersion)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 32)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(features, id: \.0) { icon, title, desc in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: icon)
                                .font(.system(size: 26))
                                .foregroundStyle(.red)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title).font(.body.weight(.semibold))
                                Text(desc).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 32)
            }
            
            Button {
                isPresented = false
            } label: {
                Text("Continue")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
            }
            .buttonStyle(HapticButtonStyle())
            .glassEffect(.regular.tint(.red).interactive(), in: Capsule())
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .frame(maxWidth: 480)
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – Root view
// ─────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────
// MARK: – Foldable iPhone (Duo) support
// ─────────────────────────────────────────────────────────────

enum DuoPosture: Equatable {
    case notDuo        // regular iPhone / iPad: normal layout
    case open          // Duo fully open: normal layout
    case laptop        // Duo half-folded: video on top, remote below
    case tent          // Duo standing like a tent: app on one screen
    case unsupported   // any other posture: show the reminder
}

enum DuoDetector {
    /// Native pixel sizes from Apple's iPhone Duo tech specs:
    /// inner display 1878 × 2670 px, outer (cover) display 1398 × 2034 px.
    static let duoNativeSizes: [CGSize] = [
        CGSize(width: 1878, height: 2670),
        CGSize(width: 1398, height: 2034)
    ]
    
    /// Landscape: inner display is 2670 wide × 1878 tall when fully open.
    /// Laptop: the top half of the inner display (fold runs horizontally).
    /// Tent: the app lives on one half of the inner display in portrait.
    static func posture(in size: CGSize) -> DuoPosture {
        let native = UIScreen.main.nativeBounds.size
        let isDuo = duoNativeSizes.contains { near(native, $0, tolerance: 0.02) }
        guard isDuo else { return .notDuo }
        
        let scale = UIScreen.main.scale
        let w = size.width * scale
        let h = size.height * scale
        let long  = max(native.width, native.height)
        let short = min(native.width, native.height)
        let landscape = w > h
        
        let isOuterOnly = near(native, duoNativeSizes[1], tolerance: 0.02)
        
        if isOuterOnly { return .unsupported }                       // closed: cover screen
        if landscape && near(w, long, 0.02)  && near(h, short, 0.02)     { return .open }
        if landscape && near(w, long, 0.02)  && near(h, short / 2, 0.03) { return .laptop }
        if !landscape && near(w, short, 0.02) && near(h, long / 2, 0.03) { return .tent }
        return .unsupported
    }
    
    private static func near(_ a: CGSize, _ b: CGSize, tolerance: CGFloat) -> Bool {
        near(a.width, b.width, tolerance) && near(a.height, b.height, tolerance)
    }
    
    private static func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat) -> Bool {
        abs(a - b) <= b * tolerance
    }
}

/// Friendly reminder shown on a Duo in an orientation we don't support.
struct DuoReminderView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                if let img = UIImage(named: "duono") {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240)
                } else {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 72, weight: .thin))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Text("Open, Laptop, or Tent please, not this orientation today!")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – Update checker
// ─────────────────────────────────────────────────────────────

/// version.json, hosted on the project's GitHub Pages site.
struct RemoteVersion: Decodable {
    let version: String
    let build: String
    let ipaURL: String
    let notes: String?
}

final class UpdateChecker: ObservableObject {
    static let manifestURL = URL(string: "https://pixel-guys-projects.github.io/YT-for-TV/version.json")!
    static let currentVersion = "2.1"
    static let currentBuild   = "imp15c"
    
    /// Your SideStore source URL, used by the "Add auto-updates" button.
    /// Leave empty to hide that button.
    static let sideStoreSourceURL = "https://pixel-guys-projects.github.io/Sideloader-Source/source.json"
    
    private static let lastCheckKey = "yt4tv.lastUpdateCheck"
    
    @Published var latest: RemoteVersion?
    @Published var message: String?
    
    /// Automatic checks run at most once a day.
    func checkIfDue() {
        if let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 3600 { return }
        check(manual: false)
    }
    
    func check(manual: Bool) {
        var request = URLRequest(url: Self.manifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                guard error == nil, let data,
                      let remote = try? JSONDecoder().decode(RemoteVersion.self, from: data) else {
                    if manual { self.message = "Couldn't check for updates. Try again later." }
                    return
                }
                if Self.isNewer(remote.version, than: Self.currentVersion) {
                    self.latest = remote
                } else if manual {
                    self.message = "You're on the latest version (\(Self.currentVersion))."
                }
            }
        }.resume()
    }
    
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
    
    /// Opens SideStore's add-source screen for this app's source.
    static var sideStoreAddURL: URL? {
        guard !sideStoreSourceURL.isEmpty,
              let encoded = sideStoreSourceURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        return URL(string: "sidestore://source?url=\(encoded)")
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – Root view
// ─────────────────────────────────────────────────────────────

struct ContentView: View {
    @EnvironmentObject private var model: WebModel
    @StateObject private var network = NetworkMonitor()
    @StateObject private var updates = UpdateChecker()
    @AppStorage("autoHideOnVideo")       private var autoHideOnVideo = true
    @AppStorage("yt4tv.lastSeenVersion") private var lastSeenVersion = ""
    @State private var showWhatsNew = false
    @Environment(\.openURL) private var openURL
    
    var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.height > geo.size.width
            let posture  = DuoDetector.posture(in: geo.size)
            ZStack {
                if posture == .laptop {
                    laptopLayout(height: geo.size.height)
                } else {
                    floatingLayout
                }
                if posture == .unsupported {
                    DuoReminderView().transition(.opacity)
                }
                if portrait && posture == .notDuo {
                    PortraitWarningView().transition(.opacity)
                }
                if !network.isConnected {
                    NoInternetView().transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: portrait)
            .animation(.easeInOut(duration: 0.25), value: posture)
            .animation(.easeInOut(duration: 0.35), value: network.isConnected)
        }
        .environmentObject(updates)
        .onChange(of: model.isVideoPlaying) { _, playing in
            if playing && autoHideOnVideo {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    model.showRemote = false
                }
            }
        }
        .onChange(of: network.isConnected) { _, connected in
            if connected { model.reload() }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            Haptics.prepare()
            updates.checkIfDue()
            if lastSeenVersion != whatsNewRevision {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    showWhatsNew = true
                }
            }
        }
        .sheet(isPresented: $showWhatsNew, onDismiss: {
            lastSeenVersion = whatsNewRevision
        }) {
            WhatsNewView(isPresented: $showWhatsNew)
                .tint(.red)
        }
        .alert("Update available", isPresented: updateBinding) {
            if let url = updates.latest.flatMap({ URL(string: $0.ipaURL) }) {
                Button("Download") { openURL(url) }
            }
            if let add = UpdateChecker.sideStoreAddURL {
                Button("Add auto-updates") { openURL(add) }
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("YT for TV \(updates.latest?.version ?? "") is out. You have \(UpdateChecker.currentVersion). Download the new IPA, or add the SideStore source for automatic updates.")
        }
        .alert("Updates", isPresented: messageBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(updates.message ?? "")
        }
    }
    
    private var updateBinding: Binding<Bool> {
        Binding(get: { updates.latest != nil },
                set: { if !$0 { updates.latest = nil } })
    }
    
    private var messageBinding: Binding<Bool> {
        Binding(get: { updates.message != nil },
                set: { if !$0 { updates.message = nil } })
    }
    
    /// Open / Tent: full web view with the floating remote.
    private var floatingLayout: some View {
        ZStack(alignment: .bottomTrailing) {
            WebContainer(model: model)
                .ignoresSafeArea()
            
            if model.showRemote {
                RemoteView()
                    .padding(.trailing, 20)
                    .padding(.bottom, 28)
                    .transition(.scale(scale: 0.05, anchor: .bottomTrailing)
                        .combined(with: .opacity))
            } else {
                TriggerButton {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                        model.showRemote = true
                    }
                }
                .padding(.trailing, 20)
                .padding(.bottom, 28)
                .transition(.scale(scale: 0.7, anchor: .bottomTrailing)
                    .combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.showRemote)
    }
    
    /// Laptop: video on the top half, remote on the bottom half.
    private func laptopLayout(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            WebContainer(model: model)
                .frame(height: height * 0.5)
            RemoteView(alwaysOpen: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – App entry point
// ─────────────────────────────────────────────────────────────

@main
struct YTforTVApp: App {
    @StateObject private var model = WebModel()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .tint(.red)
                .preferredColorScheme(.dark)
        }
    }
}
