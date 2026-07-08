import AppKit
import SwiftUI

/// A searchable list of installed apps (with icons) for the app-aware formatting settings, so the
/// user picks an app instead of typing a bundle identifier. Includes a "Browse…" escape hatch
/// (NSOpenPanel) for apps outside the standard search locations.
struct AppPickerSheet: View {
    /// Called with the chosen app; the sheet dismisses itself afterward.
    let onSelect: (InstalledApp) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    // Enumerated once when the sheet appears (disk scan); cheap enough for a one-shot picker.
    @State private var apps: [InstalledApp] = []

    private var filtered: [InstalledApp] {
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose an App")
                    .font(.headline)
                Spacer()
                Button("Browse…", action: browseForApp)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            TextField("Search apps", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 8)

            Divider()

            List(filtered) { app in
                Button {
                    onSelect(app)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(nsImage: InstalledApps.icon(for: app.url))
                            .resizable()
                            .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name)
                            Text(app.bundleIdentifier)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 440, height: 500)
        .onAppear { if apps.isEmpty { apps = InstalledApps.all() } }
    }

    /// Lets the user pick any `.app` from disk (for apps not in the standard locations).
    private func browseForApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url, let app = InstalledApps.app(at: url) {
            onSelect(app)
            dismiss()
        }
    }
}
