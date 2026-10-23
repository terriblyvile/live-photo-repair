import SwiftUI

@main
struct LivePhotoRepairApp: App {
    // Plain stored property: the App value is created once, and the SwiftUI
    // @State macro needs a plugin that ships only with full Xcode.
    private let model = AppModel()

    var body: some Scene {
        Window("Live Photo Repair", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
    }
}
