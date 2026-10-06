import Foundation

/// Slice 6f-2 (SPEC 24): music = sound without a break from a music app (or one the user marked «музыка» in
/// Settings → Приложения), not in a call and not with a video. Browsers are not music by default.
public enum MusicApps {
    /// Bundle id prefixes of known music players (a helper process like `com.spotify.client.helper` matches too).
    public static let known = [
        "com.apple.Music", "com.spotify.client", "ru.yandex.desktop.music", "ru.yandex.music", "com.vk.music",
        "com.vk.vkmusic", "com.deezer", "com.tidal.desktop", "com.coppertino.Vox", "com.swinsian.Swinsian",
        "com.foobar2000.mac", "com.colliderli.iina.music", "com.apple.iTunes",
    ]

    public static func isMusic(_ bundleID: String, marked: Set<String>) -> Bool {
        marked.contains(bundleID) || known.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
            || marked.contains { bundleID.hasPrefix($0 + ".") }
    }
}

/// Slice 6f-2 (SPEC 25): the disco. After 30 s of music a 25 % roll, a new roll after 20 more minutes of music,
/// never more than once an hour; only while Chilk is free (busy, the roll waits). A pause of more than 3 s (more than
/// a track change) ends the music.
public struct Disco: Equatable, Sendable {
    public static let after = 30.0
    public static let chance = 0.25
    public static let retry = 1200.0
    public static let rest = 3600.0
    public static let gap = 3.0
    public static let dance: ClosedRange<Double> = 20...30

    /// Seconds of music without a break.
    public private(set) var musicFor = 0.0
    private var silence = 0.0
    /// After an unlucky roll the next one waits 20 min (wall clock: a pause in the music does not shorten it).
    private var retryAt = -Double.infinity
    private var lastDance = -Double.infinity

    public init() {}

    /// Within the hour after a dance: no roll, so the sound need not even be checked.
    public func resting(now: Double) -> Bool { now - lastDance < Self.rest }

    /// One step of `seconds` at `now` (wall seconds): `music` — music is playing (not in a call, not a video);
    /// `free` — Chilk can dance. Returns true when he should dance now (`roll` in [0, 1) is taken only then).
    public mutating func tick(seconds: Double, music: Bool, free: Bool, now: Double, roll: () -> Double) -> Bool {
        if music {
            musicFor += seconds
            silence = 0
        } else {
            silence += seconds
            if silence > Self.gap { musicFor = 0 }
            return false
        }
        guard musicFor >= Self.after, now >= retryAt, !resting(now: now), free else { return false }
        retryAt = now + Self.retry
        guard roll() < Self.chance else { return false }
        lastDance = now
        return true
    }
}

extension AppRules {
    /// Slice 6f-2: apps the user marked as music (Settings → Приложения).
    public var music: Set<String> { musicMarks }
}
