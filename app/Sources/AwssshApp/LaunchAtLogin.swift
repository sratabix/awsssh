import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return nil }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status == .enabled else { return nil }
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            if SMAppService.mainApp.status == .requiresApproval {
                return "Approve Awsssh under System Settings → General → Login Items."
            }
            return "Couldn't change login item: \(error.localizedDescription)"
        }
    }
}
