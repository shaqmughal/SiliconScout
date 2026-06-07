import SiliconScoutCore
import SwiftUI

@main
struct SiliconScoutApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 640, height: 520)
        .commands {
            CommandGroup(after: .help) {
                Link("Buy Me a Coffee ☕", destination: SupportLinks.buyMeACoffee)
            }
        }
    }
}
