import SwiftUI

@main
struct SonosControlApp: App {
    var body: some Scene {
        MenuBarExtra {
            ContentView()
        } label: {
            Label("Sonos Control", systemImage: "hifispeaker.2.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
