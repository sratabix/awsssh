import AwssshIcon
import SwiftUI

@main
struct AwssshApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(model)
        } label: {
            Image(nsImage: AppIcon.menuBar(attention: model.needsAttention))
        }
        .menuBarExtraStyle(.window)
    }
}
