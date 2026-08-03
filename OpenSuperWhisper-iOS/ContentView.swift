import SwiftUI

/// Placeholder shell view for the Cycle-1 iOS host app. Nothing here but proof
/// that the app launches; Cycle 2 replaces this with the real UI.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.largeTitle)
            Text("OpenSuperWhisper iOS")
                .font(.headline)
        }
    }
}

#Preview {
    ContentView()
}
