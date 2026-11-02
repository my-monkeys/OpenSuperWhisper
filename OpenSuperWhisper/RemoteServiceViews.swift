import SwiftUI
import AppKit
import OpenSuperWhisperCore

/// Where to create a key for a built-in service, shown next to the key field.
struct ServiceKeyLink: View {
    let service: RemoteService

    var body: some View {
        Button { NSWorkspace.shared.open(service.keyPageURL) } label: {
            HStack(spacing: 4) {
                Text("Get a key")
                Image(systemName: "arrow.up.right").scaledFont(size: 10, weight: .bold)
            }
            .scaledFont(size: 13, weight: .semibold)
            .foregroundColor(STheme.accent)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help("Open \(service.displayName)'s API key page")
    }
}

/// A warning, never a block, when the pasted key plainly belongs to another service: pasting the
/// Groq key into an OpenRouter setup fails with a bare 401 otherwise.
struct KeyMismatchNotice: View {
    let service: RemoteService?
    let key: String
    var indented = false

    var body: some View {
        if let service, let prefix = service.keyPrefixHint, service.keyLooksForeign(key) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("This doesn't look like a \(service.displayName) key: they start with \(prefix). Check that you pasted the right one.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .scaledFont(size: 13)
            .foregroundColor(STheme.danger)
            .padding(.leading, indented ? 34 : 16).padding(.trailing, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
