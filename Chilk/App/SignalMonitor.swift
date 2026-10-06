import AppKit
import ChilkCore
import CoreAudio
import CoreMediaIO
import IOKit.pwr_mgt

/// Reads the user's situation without extra permissions (spike 001): idle time, lock, frontmost app and
/// whether it is fullscreen, microphone/camera used by another app, call and video power assertions.
@MainActor
final class SignalMonitor {
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let fakeIdle = ProcessInfo.processInfo.environment["CHILK_FAKE_IDLE"].flatMap(Double.init)
    /// CHILK_FAKE_AWAY_UNTIL=60 (demo/acceptance only): the user is away for the first 60 s after launch, then
    /// back at the keyboard (idle = CHILK_FAKE_IDLE or 0.5 s). Lets the timer-bubble rule run without a person.
    private let fakeAwayUntil = ProcessInfo.processInfo.environment["CHILK_FAKE_AWAY_UNTIL"].flatMap(Double.init)
    private let launched = ProcessInfo.processInfo.systemUptime
    /// Settings → apps (slice 5c): the user's categories on top of the automatic work / leisure.
    var rules: () -> AppRules = { AppRules() }

    func snapshot() -> Signals {
        // CHILK_FAKE_IDLE=3 pretends the user is typing (demo / acceptance runs without a person at the Mac).
        var idle = fakeIdle ?? CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if let fakeAwayUntil {
            let t = ProcessInfo.processInfo.systemUptime - launched
            idle = t < fakeAwayUntil ? 1_000 + t : (fakeIdle ?? 0.5)
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = (session?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
        let front = NSWorkspace.shared.frontmostApplication
        let assertions = Self.assertions(excluding: ownPID)
        return Signals(
            now: Date(),
            idle: idle,
            locked: locked || CGDisplayIsAsleep(CGMainDisplayID()) != 0,
            frontApp: front?.bundleIdentifier,
            category: rules().category(of: front?.bundleIdentifier, automatic: AppCatalog.category(of: front)),
            fullscreen: isFullscreen(front),
            inCall: assertions.call || microphoneInUseByOthers() || cameraInUse(),
            video: assertions.video
        )
    }

    // MARK: Fullscreen (spike 001): on the current Space only the front app has windows, one of them screen-wide.

    private func isFullscreen(_ front: NSRunningApplication?) -> Bool {
        guard let front, front.processIdentifier != ownPID,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let normal = windows.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        guard !normal.isEmpty,
              normal.allSatisfy({ ($0[kCGWindowOwnerPID as String] as? pid_t) == front.processIdentifier })
        else { return false }
        let widths = Set(NSScreen.screens.map { $0.frame.width })
        return normal.contains { w in
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat], let width = b["Width"], let height = b["Height"] else { return false }
            return widths.contains { abs($0 - width) < 1 } && height > 500
        }
    }

    // MARK: Microphone / camera

    private func microphoneInUseByOthers() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return false }
        for id in ids {
            var running: UInt32 = 0, pid: pid_t = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &running) == noErr, running != 0 else { continue }
            s = UInt32(MemoryLayout<pid_t>.size)
            a.mSelector = kAudioProcessPropertyPID
            AudioObjectGetPropertyData(id, &a, 0, nil, &s, &pid)
            if pid != ownPID { return true }
        }
        return false
    }

    private func cameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == 0, size > 0 else { return false }
        var devices = [CMIODeviceID](repeating: 0, count: Int(size) / MemoryLayout<CMIODeviceID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == 0 else { return false }
        for device in devices {
            var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                              mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var running: UInt32 = 0, got: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &running) == 0, running != 0 { return true }
        }
        return false
    }

    // MARK: Power assertions: «WebRTC has active PeerConnections», «Phone Call» (Telegram), «Video Wake Lock»

    private static func assertions(excluding own: pid_t) -> (call: Bool, video: Bool) {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let byPID = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return (false, false) }
        var call = false, video = false
        for (pid, list) in byPID where pid.int32Value != own {
            for a in list {
                let name = (a["AssertName"] as? String ?? "").lowercased()
                if name.contains("peerconnection") || name.contains("phone call") || name.contains("call in progress") { call = true }
                if name.contains("video wake lock") || name.contains("playing video") { video = true }
            }
        }
        return (call, video)
    }
}

/// Work vs leisure (В10). Default: work (browsers too); games/films/music are leisure.
enum AppCatalog {
    private static let leisureCategories: Set<String> = [
        "public.app-category.games", "public.app-category.entertainment", "public.app-category.music",
        "public.app-category.video", "public.app-category.sports",
    ]
    private static let leisureApps: Set<String> = [
        "com.apple.TV", "com.apple.Music", "com.apple.podcasts", "com.apple.Photos", "com.apple.iBooksX",
        "com.spotify.client", "com.valvesoftware.steam", "org.videolan.vlc", "com.colliderli.iina",
        "tv.plex.desktop", "com.apple.Arcade", "com.yandex.music",
    ]
    @MainActor private static var cache: [String: AppCategory] = [:]

    /// The automatic category, also of an app that is not running (Settings → apps).
    @MainActor
    static func automatic(bundleID id: String, url known: URL? = nil) -> AppCategory {
        if let hit = cache[id] { return hit }
        var result = AppCategory.work
        if leisureApps.contains(id) {
            result = .leisure
        } else if let url = known ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
                  let type = Bundle(url: url)?.infoDictionary?["LSApplicationCategoryType"] as? String,
                  leisureCategories.contains(type) || type.hasSuffix("-games") {
            result = .leisure
        }
        cache[id] = result
        return result
    }

    @MainActor
    static func category(of app: NSRunningApplication?) -> AppCategory {
        guard let app, let id = app.bundleIdentifier else { return .work }
        return automatic(bundleID: id, url: app.bundleURL)
    }
}
