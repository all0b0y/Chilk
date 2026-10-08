import AppKit
import AVFoundation
import ChilkApple
import CoreServices
import EventKit
import ServiceManagement
import Speech

/// Settings → «Запуск при входе» (slice 5c, SPEC «Умолчания»: on). The app itself is the login item.
@MainActor
enum LoginItem {
    enum Status: Equatable { case on, off, needsApproval }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        default: .off
        }
    }

    /// `nil` = done; otherwise why not (shown under the switch).
    static func set(_ on: Bool) -> String? {
        do {
            if on {
                // The record keeps the bundle path it was registered from (a build folder before the app was copied
                // to /Applications): register again from here once, or login starts the old copy.
                let key = "loginItemPath", here = Bundle.main.bundlePath
                if SMAppService.mainApp.status == .enabled, UserDefaults.standard.string(forKey: key) != here {
                    try? SMAppService.mainApp.unregister()
                }
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                UserDefaults.standard.set(here, forKey: key)
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Settings → «Разрешения» (slice 5c): status only; Chilk still asks on first use, never from here.
@MainActor
enum Permissions {
    enum Kind: String, CaseIterable, Identifiable {
        case microphone, speech, reminders, calendar, notes
        var id: String { rawValue }
    }

    enum State: Equatable { case granted, denied, notAsked }

    static func state(_ kind: Kind) -> State {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .notDetermined: .notAsked
            default: .denied
            }
        case .speech:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: .granted
            case .notDetermined: .notAsked
            default: .denied
            }
        case .reminders:
            switch EKEventStore.authorizationStatus(for: .reminder) {
            case .fullAccess: .granted
            case .notDetermined: .notAsked
            default: .denied
            }
        case .calendar:
            // Write-only access cannot read even Chilk's own events: only full access counts.
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: .granted
            case .notDetermined: .notAsked
            default: .denied
            }
        case .notes:
            notesState()
        }
    }

    /// Slice 8f: controlling Notes is Automation, not a privacy switch. macOS answers without asking only while Notes
    /// runs; otherwise Chilk's own last call to Notes tells.
    private static func notesState() -> State {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").isEmpty {
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Notes")
            switch AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false) {
            case noErr: return .granted
            case OSStatus(errAEEventNotPermitted): return .denied
            case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
            default: break
            }
        }
        switch UserDefaults.standard.string(forKey: AppleNotes.automationKey) {
        case "granted": return .granted
        case "denied": return .denied
        default: return .notAsked
        }
    }

    static func open(_ kind: Kind) {
        let pane = switch kind {
        case .microphone: "Privacy_Microphone"
        case .speech: "Privacy_SpeechRecognition"
        case .reminders: "Privacy_Reminders"
        case .calendar: "Privacy_Calendars"
        case .notes: "Privacy_Automation"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
