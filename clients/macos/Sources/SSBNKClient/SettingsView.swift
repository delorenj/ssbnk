#if os(macOS)
import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = ClientConfiguration.defaults()
    @State private var confirmLegacyRetirement = false

    var body: some View {
        Form {
            Section("Capture folder") {
                HStack {
                    TextField("Folder", text: $draft.captureDirectory)
                    Button("Choose…", action: chooseFolder)
                }
                Text("Screenshots and recordings are classified from this shared folder. Existing files are baselined on first use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Server") {
                TextField("SSH destination", text: $draft.sshDestination)
                TextField("Public health URL", text: $draft.publicHealthURL)
                TextField("Screenshot watch root", text: $draft.imageRemoteDirectory)
                TextField("Recording watch root", text: $draft.videoRemoteDirectory)
            }

            Section("Mappings") {
                ForEach(draft.mappings) { mapping in
                    LabeledContent(mapping.kind.label) {
                        Text("\(mapping.sourceDirectory) → \(draft.sshDestination):\(mapping.remoteDirectory)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Startup") {
                Toggle(
                    "Launch SSBNK Client at login",
                    isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
            }

            if model.legacyUploaderPresent {
                Section("Legacy uploader") {
                    Text("After this client is Healthy, retire the old LaunchAgent and delete its HTTP credential configuration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retire Legacy Uploader…", role: .destructive) {
                        confirmLegacyRetirement = true
                    }
                    .disabled(model.displayState != .healthy)
                }
            }

            HStack {
                Spacer()
                Button("Revert") { draft = model.configuration }
                Button("Save") { model.saveConfiguration(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.validationIssues().isEmpty || model.isWorking)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 680, height: 520)
        .onAppear { draft = model.configuration }
        .confirmationDialog(
            "Retire the legacy HTTP uploader?",
            isPresented: $confirmLegacyRetirement,
            titleVisibility: .visible
        ) {
            Button("Disable and Remove Credential", role: .destructive) {
                model.retireLegacyUploader(confirmed: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This unloads and removes \(LegacyMigration.agentLabel) and deletes ~/.config/ssbnk/remote.env. It runs only while the new route is Healthy.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: draft.captureDirectory, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            draft.captureDirectory = url.path
        }
    }
}
#endif
