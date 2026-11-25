import AppKit
import WebKit

/// The main window: soundcloud.com in a web view, with the login kept between launches. Closing the
/// window only hides it, so the music goes on.
final class PlayerWindow: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    static let home = URL(string: "https://soundcloud.com/discover")!

    let webView: WKWebView
    /// Messages from the page script (bridge.js).
    var onMessage: (([String: Any]) -> Void)?
    private var popups: [NSWindow] = []
    /// The compiled ad block rules, kept so the menu can switch them on and off.
    private var adRules: WKContentRuleList?
    private var urlObservation: NSKeyValueObservation?

    init() {
        let config = WKWebViewConfiguration()
        // Tests never touch the user's sign-in or choices: `--ephemeral` runs in a throwaway store, and
        // `--isolated` in a separate one that is kept on disk (WebKit hides the track from the system's
        // Now Playing in throwaway stores, as in private browsing, so only a kept one tests that).
        if Args.has("--ephemeral") {
            config.websiteDataStore = .nonPersistent()
        } else if Args.isolated {
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.testStore)
        } else {
            config.websiteDataStore = .default()
        }
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.applicationNameForUserAgent = "Version/\(Self.safariVersion) Safari/605.1.15"
        let content = config.userContentController
        if let url = Bundle.main.url(forResource: "bridge", withExtension: "js"), let source = try? String(contentsOf: url, encoding: .utf8) {
            content.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        } else {
            Log.error("bridge.js missing from the app")
        }
        content.addUserScript(WKUserScript(source: Self.pageStyleScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if Args.has("--mute") {
            // Tests: silent while something plays (volume 0, not muted, so the system still sees playback).
            content.addUserScript(WKUserScript(source: Self.muteScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        // No pinch or double-tap zoom: on a trackpad it is easy to trigger by accident, and a page this
        // size never needs it. ⌘+ and ⌘− in the View menu still zoom on purpose.
        webView.allowsMagnification = false
        webView.isInspectable = Args.has("--dev")
        if Args.isolated { Self.keepDrawingWhenHidden(webView) }
        webView.appearance = NSAppearance(named: .darkAqua)
        // No white flash before the dark page paints: the window's own dark background shows through.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Wisp"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 820, height: 560)
        window.contentView = webView
        window.isReleasedWhenClosed = false
        if Args.isolated {
            // A test copy opens on the sharpest screen, so window captures come out at full resolution.
            if let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) {
                let area = screen.visibleFrame
                window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
            } else {
                window.center()
            }
        } else {
            window.setFrameAutosaveName("WispMain")
            if !window.setFrameUsingName("WispMain") { window.center() }
        }
        super.init(window: window)
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        content.add(WeakHandler(self), name: "wisp")
        // The rules go in before the first page, so not even its first requests reach an ad server.
        AdBlock.prepare { [weak self] list in
            guard let self else { return }
            adRules = list
            if AdBlock.enabled, let list { content.add(list) }
            Log.debug("ad block \(AdBlock.enabled && list != nil ? "on" : "off")")
            webView.load(URLRequest(url: Self.startPage))
        }
        // The site changes pages without reloading; the address still updates, and is remembered.
        urlObservation = webView.observe(\.url, options: [.new]) { view, _ in
            DispatchQueue.main.async { Self.remember(view.url) }
        }
    }

    // MARK: - The page to come back to

    private static let lastPageKey = "lastPage"

    /// The test copy's own website data, apart from the user's.
    static let testStore = UUID(uuidString: "5C1D0B7E-3A52-4F0E-9B8D-7A1E2C3D4F51")!

    /// Where the listener was when the app last ran, or the Discover page.
    static var startPage: URL {
        if let s = Store.defaults.string(forKey: lastPageKey), let url = URL(string: s), isRestorable(url) { return url }
        return home
    }

    /// SoundCloud pages only, and not the sign-in or sign-out ones.
    static func isRestorable(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(),
              ["soundcloud.com", "www.soundcloud.com", "m.soundcloud.com"].contains(host) else { return false }
        let path = url.path.lowercased()
        return !["/signin", "/signup", "/login", "/logout"].contains { path.hasPrefix($0) }
    }

    private static func remember(_ url: URL?) {
        guard let url, isRestorable(url) else { return }
        Store.defaults.set(url.absoluteString, forKey: lastPageKey)
    }

    /// From the menu: switches the ad block and reloads the page so it takes effect.
    func setAdBlock(_ on: Bool) {
        AdBlock.enabled = on
        let content = webView.configuration.userContentController
        content.removeAllContentRuleLists()
        if on, let adRules { content.add(adRules) }
        Log.debug("ad block \(on ? "on" : "off")")
        webView.reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The system Safari's version, so sites see the same browser the user has.
    static var safariVersion: String {
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String else { return "18.0" }
        return version
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Runs a command of the page script (play, next, like…).
    func command(_ name: String, _ value: Double? = nil) {
        let arg = value.map { String($0) } ?? "null"
        webView.evaluateJavaScript("window.__wisp && window.__wisp.command(\(Self.jsString(name)), \(arg))") { _, error in
            if let error { Log.debug("command \(name) failed: \(error.localizedDescription)") }
        }
    }

    static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    // MARK: - Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hidden, not closed: the page and the music keep going. The Dock icon brings it back.
        sender.orderOut(nil)
        return false
    }

    // MARK: - Messages from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        onMessage?(body)
    }

    // MARK: - Navigation

    /// Pages that stay inside the app: SoundCloud itself and the sign-in pages it sends you to.
    static func staysInside(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        let inside = ["soundcloud.com", "sndcdn.com", "soundcloud.cloud",
                      "accounts.google.com", "google.com", "gstatic.com",
                      "appleid.apple.com", "apple.com", "facebook.com", "fbcdn.net"]
        return inside.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.allow); return }
        if ["mailto", "tel"].contains(url.scheme ?? "") || (action.navigationType == .linkActivated && !Self.staysInside(url)) {
            // Links to other sites open in the usual browser.
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Log.debug("loaded \(webView.url?.absoluteString ?? "-")")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page crashed: bring it back rather than leave a blank window.
        Log.error("web content process ended, reloading")
        webView.reload()
    }

    // MARK: - Pop-ups (sign-in with Google, Apple, Facebook)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, !Self.staysInside(url) {
            NSWorkspace.shared.open(url)
            return nil
        }
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: configuration)
        popup.uiDelegate = self
        popup.navigationDelegate = self
        let w = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.contentView = popup
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        if let parent = window { w.center(); parent.addChildWindow(w, ordered: .above) }
        w.makeKeyAndOrderFront(nil)
        popups.append(w)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let w = popups.first(where: { $0.contentView === webView }) else { return }
        w.parent?.removeChildWindow(w)
        w.orderOut(nil)
        popups.removeAll { $0 === w }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: tr("Отмена", "Cancel"))
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    // MARK: - Tests

    /// A test copy keeps drawing the page while its window is covered or on another Space, so snapshots
    /// and window captures show the real page with its pictures loaded (private WebKit switch).
    private static func keepDrawingWhenHidden(_ view: WKWebView) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard view.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(view.method(for: selector), to: Setter.self)(view, selector, false)
    }

    /// The app's own touches to the page: no scroll bars (the page scrolls as before, without the bar on
    /// the right), and no "Go mobile" app-store badges or legal links in the right sidebar.
    static let pageStyleScript = """
    (() => {
      const style = document.createElement("style");
      style.textContent = "::-webkit-scrollbar { display: none !important; width: 0 !important; height: 0 !important; } * { scrollbar-width: none !important; } " +
        ".sidebarModule.mobileApps, .l-sidebar-right .l-footer { display: none !important; }";
      const add = () => (document.head || document.documentElement).appendChild(style);
      if (document.documentElement) add(); else document.addEventListener("readystatechange", add, { once: true });
    })();
    """

    static let muteScript = """
    (() => {
      const play = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function () { this.volume = 0; return play.apply(this, arguments); };
    })();
    """
}

/// The content controller keeps its handlers strongly; this breaks the cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}
