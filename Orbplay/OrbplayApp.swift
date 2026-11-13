import SwiftUI

@main
struct OrbplayApp: App {
    @StateObject private var audio = SpatialAudio()

    var body: some Scene {
        MenuBarExtra("Orbplay", systemImage: audio.isProcessing ? "waveform" : "waveform.circle") {
            ContentView().environmentObject(audio)
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Orbplay") {
            ContentView().environmentObject(audio)
        }
        .defaultSize(width: 460, height: 650)
    }
}
