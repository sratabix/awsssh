import AwssshIcon
import SwiftUI

@main
struct AwssshApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(model)
        } label: {
            Image(systemName: AppIcon.symbolName)
        }
        .menuBarExtraStyle(.window)
    }
}
