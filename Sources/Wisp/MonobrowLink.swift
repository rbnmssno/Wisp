import Foundation

/// Talks to Monobrow, the notch player, over distributed notifications, the same way Spotify does:
/// every change is posted with Spotify's own keys, so Monobrow reads it with the code it already has.
///
///   app.wisp.Wisp.PlaybackStateChanged   (posted by Wisp)
///     Player State      "Playing" / "Paused" / "Stopped"
///     Track ID          "soundcloud:<path>" (the track's path on soundcloud.com)
///     Name, Artist, Album
///     Duration          milliseconds
///     Playback Position seconds
///     Artwork URL, Track URL, Liked (Bool), Likeable (Bool), Volume (0…100)
///
///   app.wisp.Wisp.Command                (posted by Monobrow)
///     Command   play, pause, playpause, next, previous, seek, volume, like, refresh
///     Value     seconds for seek, 0…100 for volume
enum MonobrowLink {
    static let stateName = Notification.Name("app.wisp.Wisp.PlaybackStateChanged")
    static let commandName = Notification.Name("app.wisp.Wisp.Command")
}

final class MonobrowPublisher: NSObject {
    var command: ((String, Double?) -> Void)?

    func start() {
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(received(_:)), name: MonobrowLink.commandName,
                                                            object: nil, suspensionBehavior: .deliverImmediately)
    }

    func publish(_ s: PlayerState) {
        var info: [String: Any] = ["Player State": s.hasTrack ? (s.playing ? "Playing" : "Paused") : "Stopped"]
        if s.hasTrack {
            info["Track ID"] = "soundcloud:" + s.id
            info["Name"] = s.title
            info["Artist"] = s.artist
            info["Album"] = s.album
            info["Duration"] = Int((s.duration * 1000).rounded())
            info["Playback Position"] = s.currentPosition
            info["Artwork URL"] = s.artwork
            info["Track URL"] = s.url
            info["Liked"] = s.liked
            info["Likeable"] = s.likeable
            info["Volume"] = Int((s.volume * 100).rounded())
        }
        DistributedNotificationCenter.default().postNotificationName(MonobrowLink.stateName, object: nil, userInfo: info, deliverImmediately: true)
    }

    func publishStopped() {
        DistributedNotificationCenter.default().postNotificationName(MonobrowLink.stateName, object: nil,
                                                                     userInfo: ["Player State": "Stopped"], deliverImmediately: true)
    }

    @objc private func received(_ note: Notification) {
        Log.debug("monobrow → \(note.userInfo ?? [:])")
        guard let name = note.userInfo?["Command"] as? String else { return }
        let value = (note.userInfo?["Value"] as? NSNumber)?.doubleValue
        DispatchQueue.main.async {
            // Monobrow speaks 0…100 for volume; the page wants 0…1.
            self.command?(name, name == "volume" ? value.map { $0 / 100 } : value)
        }
    }
}
