import SwiftUI

/// iOS host app shell (Cycle 1, commit 3). Intentionally empty: proves the target
/// graph end-to-end (compile+link+install+launch+dyld) before Cycle 2 builds the
/// real UI. No recording, no model loading, no engine code.
@main
struct OpenSuperWhisper_iOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
