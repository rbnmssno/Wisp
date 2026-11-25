import WebKit

/// Keeps ads out of SoundCloud with WebKit's content blocker (the engine Safari's ad blockers use):
/// requests are stopped before they leave, page elements are hidden before they paint, and no script
/// of ours runs for it.
///
/// - Audio ads: the player asks `api-v2.soundcloud.com/audio-ads` before a track whether to play an ad.
///   That request is blocked, so no ad is ever handed to the player; the ad audio itself is blocked too.
/// - Promoted tracks in lists, Google ad slots, the Go+, Next Pro and Artist Pro banners and links.
/// - The usual ad networks, in case the page loads them.
///
/// The same rules are in uBlock Origin's and AdGuard's lists. The sign-in pages, the bot check
/// (dwt.soundcloud.com, DataDome) and the cookie dialog are left alone.
enum AdBlock {
    private static let key = "blockAds"
    private static let identifier = "wisp-adblock"

    /// On unless switched off in the menu. `--ads` turns it off for one run (development).
    static var enabled: Bool {
        get { !Args.has("--ads") && (Store.defaults.object(forKey: key) as? Bool ?? true) }
        set { Store.defaults.set(newValue, forKey: key) }
    }

    /// Compiles the rules (a few milliseconds) and hands them over on the main thread.
    static func prepare(_ done: @escaping (WKContentRuleList?) -> Void) {
        guard let store = WKContentRuleListStore.default() else { done(nil); return }
        store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules) { list, error in
            if let error { Log.error("ad block rules did not compile: \(error)") }
            DispatchQueue.main.async { done(list) }
        }
    }

    // MARK: Rules

    /// SoundCloud's own ad addresses (host suffix, path prefix).
    private static let soundCloudPaths = [
        ("soundcloud.com", "/audio-ad"),
        ("soundcloud.com", "/promoted"),
    ]

    /// Hosts that serve only ads or ad tracking.
    private static let adHosts = [
        "promoted.soundcloud.com",
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "googletagservices.com",
        "imasdk.googleapis.com", "adservice.google.com",
        "adswizz.com", "amazon-adsystem.com", "adnxs.com", "adsrvr.org", "rubiconproject.com",
        "pubmatic.com", "openx.net", "casalemedia.com", "criteo.com", "criteo.net", "moatads.com",
        "doubleverify.com", "taboola.com", "outbrain.com",
    ]

    /// Ad audio files: only for sound, so nothing else from these hosts is touched.
    private static let adAudio = [
        ("sndcdn.com", "/audio/"),
        ("p-cdn.us", "/"),
    ]

    /// Elements hidden on soundcloud.com.
    private static let hidden = [
        "[id^=\"div-gpt-ad\"]",
        ".soundList__item:has(.sc-promoted-icon-medium)",
        ".header__goUpsell_side_by_side_experience",
        ".header__proUpsell_side_by_side_experience",
        "div.banner:has(a.nextProAnnualPromotionBanner__link)",
        ".l-product-banners",
        "div.dropdownMenu > div > ul > li:has(a.m-highlight)",
    ]

    /// `host` and any of its subdomains, then `path`.
    private static func filter(_ host: String, _ path: String) -> String {
        let escape = { (s: String) in s.replacingOccurrences(of: ".", with: "\\.") }
        return "^https?://([^/]*\\.)?" + escape(host) + "(:[0-9]+)?" + escape(path)
    }

    static var rules: String {
        var list: [[String: Any]] = []
        for (host, path) in soundCloudPaths {
            list.append(["trigger": ["url-filter": filter(host, path)], "action": ["type": "block"]])
        }
        for host in adHosts {
            list.append(["trigger": ["url-filter": filter(host, "/")], "action": ["type": "block"]])
        }
        for (host, path) in adAudio {
            list.append(["trigger": ["url-filter": filter(host, path), "resource-type": ["media"]], "action": ["type": "block"]])
        }
        list.append([
            "trigger": ["url-filter": ".*", "if-domain": ["*soundcloud.com"]],
            "action": ["type": "css-display-none", "selector": hidden.joined(separator: ", ")],
        ])
        let data = (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
