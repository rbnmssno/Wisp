import AppKit

/// One music app at a time: when Spotify starts playing, Wisp pauses, and when Wisp starts, Spotify
/// pauses.
///
/// Spotify announces every play, pause and track change with a distributed notification, so hearing
/// it needs no permission. Pausing Spotify is an Apple Event with the code from Spotify's scripting
/// dictionary; macOS asks once whether Wisp may control Spotify. The event goes out only while Spotify
/// runs, so it never launches Spotify, and pausing a Spotify that is already paused changes nothing.
final class OnePlayer: NSObject {
    static let spotifyID = "com.spotify.client"
    private static let key = "onePlayer"

    /// On unless switched off in the menu.
    static var enabled: Bool {
        get { Store.defaults.object(forKey: key) as? Bool ?? true }
        set { Store.defaults.set(newValue, forKey: key) }
    }

    /// Spotify went from not playing to playing.
    var onSpotifyStarted: (() -> Void)?

    /// What Spotify last said; nil until it says something after Wisp started.
    private var spotifyPlaying: Bool?
    private let queue = DispatchQueue(label: "app.wisp.Wisp.spotify")

    func start() {
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(spotifyChanged(_:)),
                                                            name: Notification.Name("com.spotify.client.PlaybackStateChanged"),
                                                            object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private func spotifyChanged(_ note: Notification) {
        let playing = (note.userInfo?["Player State"] as? String) == "Playing"
        DispatchQueue.main.async {
            let started = playing && self.spotifyPlaying != true
            self.spotifyPlaying = playing
            Log.debug("spotify \(playing ? "plays" : "stopped")")
            if started, Self.enabled { self.onSpotifyStarted?() }
        }
    }

    /// Wisp started playing: Spotify pauses, if it runs and may be playing.
    func wispStarted() {
        guard Self.enabled, spotifyPlaying != false,
              !NSRunningApplication.runningApplications(withBundleIdentifier: Self.spotifyID).isEmpty else { return }
        // Off the main thread: the first time, macOS waits for the user to answer its permission question.
        queue.async {
            let spotify = NSAppleEventDescriptor(bundleIdentifier: Self.spotifyID)
            guard let address = spotify.aeDesc else { return }
            let status = AEDeterminePermissionToAutomateTarget(address, Self.code("spfy"), Self.code("Paus"), true)
            guard status == noErr else {
                Log.note("not allowed to pause Spotify (\(status))")
                return
            }
            let pause = NSAppleEventDescriptor(eventClass: Self.code("spfy"), eventID: Self.code("Paus"), targetDescriptor: spotify,
                                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            do {
                try pause.sendEvent(options: [.waitForReply, .neverInteract], timeout: 3)
                Log.debug("paused Spotify")
            } catch {
                Log.error("pausing Spotify failed: \(error.localizedDescription)")
            }
        }
    }

    private static func code(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }
}
