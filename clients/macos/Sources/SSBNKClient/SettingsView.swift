#if os(macOS)
import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = ClientConfiguration.defaults()
    @State private var confirmHandover = false
    var body: some View {
        Form {
            Section("Capture folders") {
                folder("Screenshots", kind: .image)
                folder("Recordings", kind: .video)
                Text("Initial setup and folder changes baseline existing files. Restart finds missed captures.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Server") {
                TextField("API origin", text: Binding(get: { draft.apiOrigin ?? draft.resolvedOrigin }, set: { draft.apiOrigin = $0 }))
                TextField("DeLoSecrets op:// reference", text: Binding(get: { draft.credentialReference ?? "" }, set: { draft.credentialReference = $0 }))
                Button("Test connection") { model.testConnection() }
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLoginEnabled }, set: { model.setLaunchAtLogin($0) }))
            }
            if model.legacyUploaderPresent {
                Section("Legacy handover") {
                    Text("Automatic submission is gated. Verify vault migration, a controlled capture outside old watched roots, and legacy inactivity before cutover. Legacy credentials are never deleted here.").font(.caption)
                    Button("Verify handover…") { confirmHandover = true }
                }
            }
            if let error = model.attentionMessage { Text(error).foregroundStyle(.orange).font(.caption) }
            HStack {
                Button("Revert") { draft = model.configuration }
                Spacer()
                Button("Save") { draft.version = 2; model.saveConfiguration(draft) }.disabled(!draft.validationIssues().isEmpty)
            }
        }.formStyle(.grouped).padding().frame(width: 680, height: 540)
        .onAppear { draft = model.configuration }
        .confirmationDialog("Verify a controlled capture and vault migration, then disable the legacy uploader?", isPresented: $confirmHandover) {
            Button("Verify and cut over") { model.retireLegacyUploader(confirmed: true) }
            Button("Cancel", role: .cancel) {}
        }
    }
    private func folder(_ label: String, kind: MediaKind) -> some View {
        HStack {
            TextField(label, text: Binding(get: { kind == .image ? draft.screenshotDirectory ?? draft.captureDirectory : draft.recordingDirectory ?? draft.captureDirectory }, set: { if kind == .image { draft.screenshotDirectory = $0 } else { draft.recordingDirectory = $0 } }))
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    if kind == .image { draft.screenshotDirectory = url.path } else { draft.recordingDirectory = url.path }
                }
            }
        }
    }
}
#endif
