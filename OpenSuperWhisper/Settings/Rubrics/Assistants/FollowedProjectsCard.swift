import SwiftUI

/// Every project an agent has asked from, with its own switch: off, that project's agents stay
/// in their terminal. A turned-off folder covers everything below it, and the captions say so.
struct FollowedProjectsCard: View {
    @ObservedObject var model: AssistantsSettingsModel
    let onClose: () -> Void

    var body: some View {
        ModalCard(maxWidth: 600, maxHeight: 560, onClose: onClose) {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
                ScrollView {
                    list
                        .padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Followed projects")
                    .scaledFont(size: 22, weight: .bold)
                    .foregroundColor(STheme.textBright)
                Text("Off, a project's agents stay in their terminal. Turning a folder off covers the projects inside it.")
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            CloseButton(action: onClose)
        }
    }

    @ViewBuilder private var list: some View {
        if model.projects.isEmpty {
            Text("A project shows up here the first time one of its agents asks for you.")
                .scaledFont(size: 13)
                .foregroundColor(STheme.hint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.projects, id: \.self) { path in
                    ProjectRow(model: model, path: path)
                }
            }
            .background(STheme.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(STheme.border, lineWidth: 1))
        }
    }
}

private struct ProjectRow: View {
    @ObservedObject var model: AssistantsSettingsModel
    let path: String

    var body: some View {
        let parent = model.folderTurningOff(path)
        let coveredInside = model.projectsOnlyTurnedOff(by: path)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: URL(fileURLWithPath: path).lastPathComponent)
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundColor(STheme.textBright)
                    Text(verbatim: AgentSettings.abbreviated(path))
                        .scaledFont(size: 13)
                        .foregroundColor(STheme.hint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                // Under a turned-off folder the switch stays put, even when the project is also
                // off on its own: the folder's rule covers everything below it, turning the
                // folder on from here would also turn on its other projects without saying so,
                // and turning this one on would change nothing until the folder is back on.
                SSwitch(isOn: Binding(
                    get: { model.isProjectOn(path) },
                    set: { model.setProject(path, on: $0) }))
                .disabled(!model.enabled || parent != nil)
            }
            if let parent {
                caption("Off because it is inside \(AgentSettings.abbreviated(parent)), which is off. Turn that folder back on to use the panel here.",
                        color: STheme.warn)
            } else if coveredInside > 0 {
                caption(coveredInside == 1
                        ? "Also turns off 1 project inside it."
                        : "Also turns off \(coveredInside) projects inside it.",
                        color: STheme.hint)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(STheme.border).frame(height: 1) }
    }

    private func caption(_ text: LocalizedStringKey, color: Color) -> some View {
        Text(text)
            .scaledFont(size: 13)
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
