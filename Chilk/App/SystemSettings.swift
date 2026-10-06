import AppKit
import AVFoundation
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
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
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
        case microphone, speech, reminders
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
        }
    }

    static func open(_ kind: Kind) {
        let pane = switch kind {
        case .microphone: "Privacy_Microphone"
        case .speech: "Privacy_SpeechRecognition"
        case .reminders: "Privacy_Reminders"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
