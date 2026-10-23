// YT for TV — Swift Playgrounds Edition  |  Requires iPadOS 26+

import SwiftUI
import WebKit
import Combine

// ─────────────────────────────────────────────────────────────
// MARK: – Web engine
// ─────────────────────────────────────────────────────────────

final class WebManager: NSObject, ObservableObject {
    let webView: WKWebView
    @Published var isSearchActive = false
    @Published var isVideoPlaying = false
    @Published var showRemote     = false
    private let messageProxy      = WeakMessageHandler()

    private let tvUserAgent =
        "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0) " +
        "AppleWebKit/538.1 (KHTML, like Gecko) " +
        "Version/6.0 TV Safari/538.1"

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        config.userContentController.addUserScript(
            WKUserScript(
                source: WebManager.bootJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
        )
        config.userContentController.add(messageProxy, name: "yt4tv")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .black
        webView.isOpaque = true

        super.init()
        webView.customUserAgent = tvUserAgent
        messageProxy.target = self
        webView.navigationDelegate = self

        if let url = URL(string: "https://www.youtube.com/tv") {
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: Key injection

    func sendKey(keyCode: Int, key: String) {
        let domCode = Self.domCode(for: keyCode)
        let js = """
        (function(){
            var el = document.activeElement || document.body;
            var o = {
                bubbles: true, cancelable: true, composed: true,
                key: '\(key)', code: '\(domCode)',
                keyCode: \(keyCode), which: \(keyCode), charCode: 0
            };
            el.dispatchEvent(new KeyboardEvent('keydown', o));
            setTimeout(function(){ el.dispatchEvent(new KeyboardEvent('keyup', o)); }, 55);
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func injectSearchText(_ text: String) {
        let safe = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'",  with: "\\'")
        let js = """
        (function(){
            var inp = document.querySelector(
                'input[type=search],[class*="search"] input,[id*="search"] input,input'
            );
            if (!inp && document.activeElement &&
                ['INPUT','TEXTAREA'].includes(document.activeElement.tagName)) {
                inp = document.activeElement;
            }
            if (inp) {
                Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')
                      .set.call(inp, '\(safe)');
                inp.dispatchEvent(new Event('input',  { bubbles: true }));
                inp.dispatchEvent(new Event('change', { bubbles: true }));
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: Helpers

    private static func domCode(for keyCode: Int) -> String {
        switch keyCode {
        case  8: return "Backspace"
        case 13: return "Enter"
        case 27: return "Escape"
        case 32: return "Space"
        case 37: return "ArrowLeft"
        case 38: return "ArrowUp"
        case 39: return "ArrowRight"
        case 40: return "ArrowDown"
        default: return ""
        }
    }

    private static let bootJS = """
    (function(){
        function notifySearch(active) {
            try { window.webkit.messageHandlers.yt4tv.postMessage({ type: 'search', active: active }); }
            catch(_) {}
        }
        document.addEventListener('focusin', function(e) {
            var tag = (e.target ? e.target.tagName : '').toUpperCase();
            notifySearch(tag === 'INPUT' || tag === 'TEXTAREA');
        }, true);
        document.addEventListener('focusout', function() {
            setTimeout(function() {
                var el  = document.activeElement;
                var tag = el ? el.tagName.toUpperCase() : '';
                notifySearch(tag === 'INPUT' || tag === 'TEXTAREA');
            }, 200);
        }, true);
        var lastHash = '';
        setInterval(function() {
            if (window.location.hash !== lastHash) {
                lastHash = window.location.hash;
                if (lastHash.indexOf('search') > -1 || lastHash.indexOf('query') > -1) {
                    notifySearch(true);
                }
            }
        }, 300);
        function notifyVideo() {
            var v = document.querySelector('video');
            var playing = !!(v && !v.paused && !v.ended && v.readyState > 2);
            try { window.webkit.messageHandlers.yt4tv.postMessage({ type: 'video', playing: playing }); }
            catch(_) {}
        }
        setInterval(notifyVideo, 800);
    })();
    """
}

extension WebManager: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(WebManager.bootJS, completionHandler: nil)
    }
}

extension WebManager: WKScriptMessageHandler {
    func userContentController(_ uc: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "yt4tv",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        DispatchQueue.main.async {
            switch type {
            case "search": self.isSearchActive = body["active"] as? Bool ?? false
            case "video":  self.isVideoPlaying = body["playing"] as? Bool ?? false
            default: break
            }
        }
    }
}

private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    func userContentController(_ uc: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(uc, didReceive: message)
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – UIViewController
//
// UIKit z-order (bottom → top):
//   [0] WKWebView          — full-screen web content
//   [1] touchShield UIView — full-screen, clear, shown only when remote
//                            is open. Absorbs gap-taps at UIKit level.
//   [2] triggerHC.view     — tiny 52×52 pinned to bottom-right corner.
//                            Only this corner is blocked when remote is
//                            closed → video taps work freely everywhere else.
//   [3] panelHC.view       — full-screen, hidden when remote is closed,
//                            so it never intercepts taps on the video.
// ─────────────────────────────────────────────────────────────

struct YouTubeTVContainer: UIViewControllerRepresentable {
    @EnvironmentObject var webManager: WebManager
    func makeUIViewController(context: Context) -> YouTubeTVViewController {
        YouTubeTVViewController(webManager: webManager)
    }
    func updateUIViewController(_ vc: YouTubeTVViewController, context: Context) {}
}

final class YouTubeTVViewController: UIViewController {
    private let webManager: WebManager
    private var cancellables = Set<AnyCancellable>()

    private let touchShield: UIView = {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true
        v.isHidden = true
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private var triggerHC: UIHostingController<AnyView>!
    private var panelHC:   UIHostingController<AnyView>!

    init(webManager: WebManager) {
        self.webManager = webManager
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // z=0  WKWebView
        let wv = webManager.webView
        wv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wv)
        pinEdges(of: wv, to: view)

        // z=1  Touch shield
        view.addSubview(touchShield)
        pinEdges(of: touchShield, to: view)

        // z=2  Trigger button — 52×52, bottom-right corner only
        triggerHC = UIHostingController(
            rootView: AnyView(TriggerButtonView().environmentObject(webManager))
        )
        triggerHC.view.backgroundColor = .clear
        triggerHC.view.isOpaque = false
        triggerHC.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(triggerHC)
        view.addSubview(triggerHC.view)
        NSLayoutConstraint.activate([
            triggerHC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            triggerHC.view.bottomAnchor  .constraint(equalTo: view.bottomAnchor,   constant: -28),
            triggerHC.view.widthAnchor   .constraint(equalToConstant: 52),
            triggerHC.view.heightAnchor  .constraint(equalToConstant: 52)
        ])
        triggerHC.didMove(toParent: self)

        // z=3  Remote panel — full-screen, hidden until remote opens
        panelHC = UIHostingController(
            rootView: AnyView(RemotePanelView().environmentObject(webManager))
        )
        panelHC.view.backgroundColor = .clear
        panelHC.view.isOpaque = false
        panelHC.view.isHidden = true
        panelHC.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(panelHC)
        view.addSubview(panelHC.view)
        pinEdges(of: panelHC.view, to: view)
        panelHC.didMove(toParent: self)

        addSwipeGestures()
        observeRemoteState()
    }

    private func observeRemoteState() {
        webManager.$showRemote
            .receive(on: DispatchQueue.main)
            .sink { [weak self] showing in
                guard let self else { return }
                self.touchShield.isHidden    = !showing
                self.triggerHC.view.isHidden =  showing

                if showing {
                    // Reveal immediately so SwiftUI can animate the panel in
                    self.panelHC.view.isHidden = false
                } else {
                    // Wait for the exit animation to finish (~0.55 s) before hiding
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                        guard let self, !self.webManager.showRemote else { return }
                        self.panelHC.view.isHidden = true
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func addSwipeGestures() {
        let directions: [UISwipeGestureRecognizer.Direction] = [.right, .left, .down, .up]
        for dir in directions {
            let gr = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            gr.direction = dir
            gr.numberOfTouchesRequired = 1
            gr.delegate = self
            view.addGestureRecognizer(gr)
        }
    }

    @objc private func handleSwipe(_ gr: UISwipeGestureRecognizer) {
        let keyCode: Int
        let key: String
        switch gr.direction {
        case .right:
            keyCode = 37; key = "ArrowLeft"
        case .left:
            keyCode = 39; key = "ArrowRight"
        case .up:
            keyCode = 40; key = "ArrowDown"
        case .down:
            if webManager.isVideoPlaying {
                keyCode = 27; key = "Escape"
            } else {
                keyCode = 38; key = "ArrowUp"
            }
        default:
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        webManager.sendKey(keyCode: keyCode, key: key)
    }

    private func pinEdges(of child: UIView, to parent: UIView) {
        NSLayoutConstraint.activate([
            child.topAnchor    .constraint(equalTo: parent.topAnchor),
            child.bottomAnchor .constraint(equalTo: parent.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
        ])
    }
}

extension YouTubeTVViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldBeRequiredToFailBy o: UIGestureRecognizer) -> Bool { false }
}

// ─────────────────────────────────────────────────────────────
// MARK: – Trigger button (lives in a 52×52 UIHostingController)
// ─────────────────────────────────────────────────────────────

struct TriggerButtonView: View {
    @EnvironmentObject var webManager: WebManager
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true

    var body: some View {
        Button {
            // Low dampingFraction = bouncy stretch as the panel grows
            withAnimation(.spring(response: 0.52, dampingFraction: 0.60)) {
                webManager.showRemote = true
            }
            if hapticsEnabled {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        } label: {
            Image(systemName: "appletvremote.gen4.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .glassEffect(in: Circle())
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – Remote panel overlay (full-screen UIHostingController)
// ─────────────────────────────────────────────────────────────

struct RemotePanelView: View {
    @EnvironmentObject var webManager: WebManager
    @AppStorage("autoHideOnVideo") private var autoHideOnVideo = true

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Fills the UIHostingController frame without consuming any taps
            Color.clear.allowsHitTesting(false)

            // SwiftUI conditional drives the transition animation.
            // UIKit shows/hides panelHC.view separately (with a delay on hide
            // so this exit animation plays out before the view disappears).
            if webManager.showRemote {
                RemoteControlView()
                    .padding(.trailing, 20)
                    .padding(.bottom, 28)
                    .transition(
                        .asymmetric(
                            // Grows from a tiny point at the trigger button corner
                            insertion: .scale(scale: 0.04, anchor: .bottomTrailing)
                                       .combined(with: .opacity),
                            // Shrinks back to that corner on close
                            removal:   .scale(scale: 0.04, anchor: .bottomTrailing)
                                       .combined(with: .opacity)
                        )
                    )
            }
        }
        .onChange(of: webManager.isVideoPlaying) { _, playing in
            if playing && autoHideOnVideo {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    webManager.showRemote = false
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – Remote control panel
// ─────────────────────────────────────────────────────────────

struct RemoteControlView: View {
    @EnvironmentObject private var webManager: WebManager
    @State private var showSettings = false
    @AppStorage("hapticsEnabled")  private var hapticsEnabled  = true
    @AppStorage("autoHideOnVideo") private var autoHideOnVideo = true

    private let S: CGFloat = 52
    private let G: CGFloat = 5

    private var panelWidth: CGFloat {
        showSettings ? 310 : (S * 3 + G * 2 + 32)
    }

    var body: some View {
        // GlassEffectContainer lets adjacent glass elements (the D-pad buttons
        // and the outer panel) merge and stretch into each other — the "liquid"
        // quality. The outer panel and each button both carry .glassEffect(), so
        // they all participate in the same morphing render pass.
        GlassEffectContainer {
            VStack(spacing: 0) {
                headerRow
                Capsule()
                    .fill(.white.opacity(0.15))
                    .frame(height: 0.5)
                    .padding(.horizontal, 10)
                if showSettings {
                    settingsBody
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal:   .move(edge: .trailing).combined(with: .opacity)))
                } else {
                    dpadBody
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal:   .move(edge: .leading).combined(with: .opacity)))
                }
            }
            // Width animates with a spring so the panel stretches smoothly
            // when toggling between D-pad (narrow) and Settings (wide)
            .frame(width: panelWidth)
            .animation(.spring(response: 0.38, dampingFraction: 0.72), value: showSettings)
            .glassEffect(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }

    // MARK: Header — title + gear icon (X is in the button row)

    private var headerRow: some View {
        HStack(spacing: 4) {
            Text(showSettings ? "Settings" : "Remote")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.leading, 4)
            Spacer()
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    showSettings.toggle()
                }
            } label: {
                Image(systemName: showSettings ? "gamecontroller" : "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    // MARK: D-pad — ✕ is in the bottom row alongside ⏯ and ⎋

    private var dpadBody: some View {
        VStack(spacing: G) {
            remBtn("chevron.up") {
                webManager.sendKey(keyCode: 38, key: "ArrowUp")
            }
            HStack(spacing: G) {
                remBtn("chevron.left") {
                    webManager.sendKey(keyCode: 37, key: "ArrowLeft")
                }
                remLbl("OK") {
                    webManager.sendKey(keyCode: 13, key: "Enter")
                }
                remBtn("chevron.right") {
                    webManager.sendKey(keyCode: 39, key: "ArrowRight")
                }
            }
            remBtn("chevron.down") {
                webManager.sendKey(keyCode: 40, key: "ArrowDown")
            }
            Capsule()
                .fill(.white.opacity(0.2))
                .frame(width: S * 3 + G * 2, height: 0.5)
                .padding(.vertical, 2)
            HStack(spacing: G) {
                remBtn("playpause.fill") {
                    webManager.sendKey(keyCode: 32, key: " ")
                }
                remBtn("arrow.uturn.backward") {
                    webManager.sendKey(keyCode: 27, key: "Escape")
                }
                remBtn("xmark") {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                        webManager.showRemote = false
                    }
                }
            }
        }
        .padding(16)
    }

    // MARK: Settings — wider panel with proper sections

    private var settingsBody: some View {
        VStack(alignment: .leading, spacing: 0) {

            sectionLabel("Playback")
            settingsGroup {
                settingButton(icon: "arrow.clockwise", tint: .blue,
                              title: "Reload Page",
                              detail: "Refresh the YouTube TV interface") {
                    webManager.webView.reload()
                }
                Divider().opacity(0.18).padding(.leading, 52)
                settingButton(icon: "house", tint: .blue,
                              title: "Go to Home",
                              detail: "Return to the YouTube TV home screen") {
                    if let url = URL(string: "https://www.youtube.com/tv") {
                        webManager.webView.load(URLRequest(url: url))
                    }
                    withAnimation { webManager.showRemote = false }
                }
            }

            sectionLabel("Preferences")
            settingsGroup {
                settingToggle(icon: "video.slash", tint: .indigo,
                              title: "Auto-hide on Video",
                              detail: "Dismiss remote when a video starts",
                              isOn: $autoHideOnVideo)
                Divider().opacity(0.18).padding(.leading, 52)
                settingToggle(icon: "hand.tap", tint: .indigo,
                              title: "Haptic Feedback",
                              detail: "Vibrate when pressing buttons",
                              isOn: $hapticsEnabled)
            }

            Button {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                    webManager.showRemote = false
                }
            } label: {
                Text("Close Remote")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(
                        .white.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.38))
            .tracking(0.7)
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(
                .white.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .padding(.horizontal, 14)
    }

    @ViewBuilder
    private func settingButton(icon: String, tint: Color,
                               title: String, detail: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title) .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.42))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.25))
            }
            .padding(.horizontal, 14)
            .frame(height: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func settingToggle(icon: String, tint: Color,
                               title: String, detail: String,
                               isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title) .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.42))
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().tint(.blue)
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
    }

    @ViewBuilder
    private func remBtn(_ sfSymbol: String, action: @escaping () -> Void) -> some View {
        RemoteButton(icon: sfSymbol, width: S, height: S,
                     haptics: hapticsEnabled, action: action)
    }

    @ViewBuilder
    private func remLbl(_ text: String, action: @escaping () -> Void) -> some View {
        RemoteButton(label: text, width: S, height: S,
                     haptics: hapticsEnabled, action: action)
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – Remote button with Liquid Glass
// ─────────────────────────────────────────────────────────────

struct RemoteButton: View {
    var icon:    String? = nil
    var label:   String? = nil
    let width:   CGFloat
    let height:  CGFloat
    let haptics: Bool
    let action:  () -> Void

    @State private var pressed = false

    var body: some View {
        Button {
            if haptics { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            action()
        } label: {
            buttonContent
                .frame(width: width, height: height)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(pressed ? 0.18 : 0))
                )
                .scaleEffect(pressed ? 0.82 : 1.0)
                // Fast snap down when pressed, bouncy overshoot on release
                .animation(
                    pressed
                        ? .easeOut(duration: 0.07)
                        : .spring(response: 0.38, dampingFraction: 0.48),
                    value: pressed
                )
        }
        .buttonStyle(.plain)
        .glassEffect(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        pressed = true
                        // Fast snap down on press
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    }
                }
                .onEnded { _ in pressed = false }
        )
    }

    @ViewBuilder
    private var buttonContent: some View {
        if let icon = icon {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        } else if let label = label {
            Text(label)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – Search keyboard bridge
// ─────────────────────────────────────────────────────────────

struct SearchKeyboardBridge: UIViewRepresentable {
    @EnvironmentObject var webManager: WebManager

    func makeUIView(context: Context) -> PassthroughTextField {
        let tf = PassthroughTextField()
        tf.autocorrectionType     = .no
        tf.autocapitalizationType = .none
        tf.spellCheckingType      = .no
        tf.smartDashesType        = .no
        tf.smartQuotesType        = .no
        tf.keyboardType           = .asciiCapable
        tf.returnKeyType          = .search
        tf.alpha                  = 0.01
        tf.delegate               = context.coordinator
        return tf
    }

    func updateUIView(_ tf: PassthroughTextField, context: Context) {
        if webManager.isSearchActive {
            guard !tf.isFirstResponder else { return }
            tf.text = ""
            context.coordinator.previousText = ""
            DispatchQueue.main.async { tf.becomeFirstResponder() }
        } else {
            if tf.isFirstResponder { tf.resignFirstResponder() }
            tf.text = ""
            context.coordinator.previousText = ""
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(webManager: webManager) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let webManager: WebManager
        var previousText = ""

        init(webManager: WebManager) { self.webManager = webManager }

        func textField(_ textField: UITextField,
                       shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            let current  = textField.text ?? ""
            let nsString = current as NSString
            let next     = nsString.replacingCharacters(in: range, with: string)
            defer { previousText = next }

            if string.isEmpty {
                let deleted = max(previousText.count - next.count, 1)
                for _ in 0 ..< deleted {
                    webManager.sendKey(keyCode: 8, key: "Backspace")
                }
            } else {
                for ch in string {
                    webManager.sendKey(keyCode: Int(ch.asciiValue ?? 0), key: String(ch))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self.webManager.injectSearchText(next)
            }
            return true
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            webManager.sendKey(keyCode: 13, key: "Enter")
            textField.text = ""
            previousText   = ""
            return true
        }
    }
}

final class PassthroughTextField: UITextField {
    override var canBecomeFirstResponder: Bool { true }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – What's New
// ─────────────────────────────────────────────────────────────

private struct WNFeature: Identifiable {
    let id    = UUID()
    let icon:  String
    let title: String
    let body:  String
}

private struct WNSection: Identifiable {
    let id      = UUID()
    let heading: String
    let items:   [WNFeature]
}

private let wnSections: [WNSection] = [
    WNSection(heading: "Design", items: [
        WNFeature(
            icon:  "circle.hexagongrid",
            title: "Liquid Glass Interface",
            body:  "Every control uses Apple's refracting Liquid Glass material — buttons that stretch, merge, and catch light naturally."
        )
    ]),
    WNSection(heading: "Navigation", items: [
        WNFeature(
            icon:  "hand.draw",
            title: "Gesture Navigation",
            body:  "Swipe left, right, up, or down anywhere on screen to move focus through the YouTube TV interface."
        ),
        WNFeature(
            icon:  "arrow.down.to.line",
            title: "Smart Swipe Back",
            body:  "While a video is playing, swipe down to instantly exit the player and return to browsing."
        )
    ]),
    WNSection(heading: "Productivity", items: [
        WNFeature(
            icon:  "keyboard",
            title: "Native Search Handoff",
            body:  "Your iPadOS keyboard appears automatically when YouTube TV enters search. Just start typing."
        ),
        WNFeature(
            icon:  "moon.zzz",
            title: "Display Always On",
            body:  "The screen stays awake while the app is active — no more auto-lock interrupting playback."
        )
    ])
]

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("What's New in")
                                .font(.system(size: 34, weight: .bold))
                                .foregroundStyle(.white)
                            Text("YT for TV")
                                .font(.system(size: 34, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .padding(.top, 48)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 36)

                        ForEach(wnSections) { section in
                            Text(section.heading.uppercased())
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.gray)
                                .tracking(0.8)
                                .padding(.horizontal, 32)
                                .padding(.bottom, 14)

                            VStack(alignment: .leading, spacing: 24) {
                                ForEach(section.items) { item in
                                    HStack(alignment: .top, spacing: 18) {
                                        Image(systemName: item.icon)
                                            .font(.system(size: 26, weight: .light))
                                            .foregroundStyle(.blue)
                                            .frame(width: 34)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.title)
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundStyle(.white)
                                            Text(item.body)
                                                .font(.system(size: 14))
                                                .foregroundStyle(Color(white: 0.5))
                                                .fixedSize(horizontal: false, vertical: true)
                                                .lineSpacing(2)
                                        }
                                    }
                                    .padding(.horizontal, 32)
                                }
                            }
                            .padding(.bottom, 32)
                        }
                    }
                }

                VStack(spacing: 0) {
                    Divider().opacity(0.12)
                    // Solid blue Continue button (per request)
                    Button {
                        dismiss()
                    } label: {
                        Text("Continue")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(.blue, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
                    .padding(.bottom, 36)
                }
                .background(.black)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – Root content view
// ─────────────────────────────────────────────────────────────

struct ContentView: View {
    @EnvironmentObject private var webManager: WebManager
    @State private var showWhatsNew = false

    var body: some View {
        ZStack {
            YouTubeTVContainer().ignoresSafeArea()
            if webManager.isSearchActive {
                SearchKeyboardBridge()
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            checkWhatsNew()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sheet(isPresented: $showWhatsNew) { WhatsNewView() }
    }

    private func checkWhatsNew() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let seen    = UserDefaults.standard.string(forKey: "yt4tv.lastSeenVersion")
        guard seen != version else { return }
        UserDefaults.standard.set(version, forKey: "yt4tv.lastSeenVersion")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { showWhatsNew = true }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: – App entry
// ─────────────────────────────────────────────────────────────

@main
struct YTforTVApp: App {
    @StateObject private var webManager = WebManager()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(webManager)
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
        }
    }
}
