#if os(macOS)
import AppKit
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmExistingSync = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(model.displayState.rawValue)
                    .font(.headline)
                Spacer()
                if model.queueSnapshot.queueDepth > 0 {
                    Text("\(model.queueSnapshot.queueDepth) queued")
                        .foregroundStyle(.secondary)
                }
            }

            if let activity = model.activityMessage {
                ProgressView(activity)
                    .controlSize(.small)
            }

            Divider()
            Text("Configured routes")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(model.configuration.mappings) { mapping in
                VStack(alignment: .leading, spacing: 2) {
                    Text(mapping.kind.label)
                        .font(.subheadline.weight(.semibold))
                    Text(mapping.sourceDirectory)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .help(mapping.sourceDirectory)
                    Text("→ \(model.configuration.sshDestination):\(mapping.remoteDirectory)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("\(model.configuration.sshDestination):\(mapping.remoteDirectory)")
                }
            }

            if let message = model.attentionMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(model.displayState == .needsAttention ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let success = model.queueSnapshot.lastSuccessAt {
                Text("Last success: \(success.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Button("Test Connection") { model.testConnection() }
                Button("Sync Now") { model.syncNow() }
                Button("Sync Existing…") { confirmExistingSync = true }
            }
            .disabled(model.isWorking)

            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLogin($0) }
                )
            )

            HStack {
                Button("Settings…") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 440)
        .confirmationDialog(
            "Sync files that existed before SSBNK Client was installed?",
            isPresented: $confirmExistingSync,
            titleVisibility: .visible
        ) {
            Button("Sync Existing Captures") { model.syncExisting() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Supported files that are not already pending or delivered will be queued once. Originals remain on this Mac.")
        }
    }

    private var statusColor: Color {
        switch model.displayState {
        case .healthy: return .green
        case .syncing: return .blue
        case .needsAttention: return .orange
        }
    }
}
#endif
