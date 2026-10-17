import SwiftUI

@main struct MyApp: App {
    var body: some Scene {
        Window("Canvas 仓鼠", id: "hamster") {
            ContentView()
        }
        .defaultSize(width: 742, height: 605)
        .windowResizability(.contentMinSize)
    }
}
