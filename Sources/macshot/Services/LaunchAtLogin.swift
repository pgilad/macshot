import Cocoa
import ServiceManagement

/// The login item. macOS keeps its state: the user can turn it off in System Settings ›
/// General › Login Items, or macOS can wait for the user to approve it there. Settings
/// shows that state. The "launchAtLogin" default only carries the choice through a
/// settings export and import.
enum LaunchAtLogin {
    static let defaultsKey = "launchAtLogin"

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// Registers or unregisters the login item. Returns a message for the user when
    /// macOS refuses, or nil.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "macshot cannot \(enabled ? "turn on" : "turn off") launch at login: \(error.localizedDescription)"
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
