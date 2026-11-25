import Foundation
import QuartzCore

/// What plays on the page, as the page script reports it.
struct PlayerState: Equatable {
    var id = ""
    var url = ""
    var title = ""
    var artist = ""
    var album = ""
    var artwork = ""
    /// Seconds.
    var duration: Double = 0
    /// Seconds, at the moment `stamp`.
    var position: Double = 0
    var stamp: CFTimeInterval = 0
    var playing = false
    var hasTrack = false
    var liked = false
    var likeable = false
    /// 0…1.
    var volume: Double = 1

    init() {}

    init(message m: [String: Any]) {
        id = m["id"] as? String ?? ""
        url = m["url"] as? String ?? ""
        title = m["title"] as? String ?? ""
        artist = m["artist"] as? String ?? ""
        album = m["album"] as? String ?? ""
        artwork = m["artwork"] as? String ?? ""
        duration = (m["duration"] as? NSNumber)?.doubleValue ?? 0
        position = (m["position"] as? NSNumber)?.doubleValue ?? 0
        stamp = CACurrentMediaTime()
        playing = m["playing"] as? Bool ?? false
        hasTrack = m["hasTrack"] as? Bool ?? false
        liked = m["liked"] as? Bool ?? false
        likeable = m["likeable"] as? Bool ?? false
        volume = (m["volume"] as? NSNumber)?.doubleValue ?? 1
    }

    /// The position now, counted on from the last report while playing.
    var currentPosition: Double {
        guard playing else { return position }
        let p = position + (CACurrentMediaTime() - stamp)
        return duration > 0 ? min(p, duration) : p
    }

    /// Same track and state, ignoring small position drift.
    func sameAs(_ o: PlayerState) -> Bool {
        id == o.id && title == o.title && artist == o.artist && artwork == o.artwork && duration == o.duration &&
            playing == o.playing && liked == o.liked && likeable == o.likeable && abs(volume - o.volume) < 0.005 &&
            abs(currentPosition - o.currentPosition) < 1.5
    }
}
