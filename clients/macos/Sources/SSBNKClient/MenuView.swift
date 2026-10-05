#if os(macOS)
import AppKit
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmExistingSync = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.displayState.rawValue, systemImage: model.displayState.systemImageName).font(.headline)
            if let message = model.attentionMessage { Text(message).font(.caption).foregroundStyle(.orange) }
            Divider()
            if model.queueSnapshot.history.isEmpty {
                Text("No captures yet. Existing files stay baselined until Sync existing.").foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(model.queueSnapshot.history.prefix(50))) { row in
                        HStack(alignment: .top) {
                            Image(systemName: icon(row)).foregroundStyle(rowColor(row))
                            VStack(alignment: .leading, spacing: 3) {
                                Button(URL(fileURLWithPath: row.sourcePath).lastPathComponent) { if row.phase == "ready" { model.copyCapture(row.id) } }
                                    .buttonStyle(.plain)
                                Text("\(row.createdAt.formatted(date: .omitted, time: .standard)) · \(row.kind.rawValue) · \(status(row))").font(.caption).foregroundStyle(.secondary)
                                if let error = row.lastError ?? row.copyWarning { Text(error).font(.caption).foregroundStyle(.orange) }
                                HStack {
                                    if row.phase == "ready" {
                                        Button(row.copyWarning == nil ? "Copy" : "Retry copy") { model.copyCapture(row.id) }
                                        Button("Open") { model.openCapture(row) }
                                    }
                                    if row.phase == "error" { Button("Retry") { model.retryCapture(row.id) } }
                                }.font(.caption)
                            }
                        }
                    }
                }
            }.frame(maxHeight: 360)
            Divider()
            HStack {
                Button("Sync now") { model.syncNow() }
                Button("Sync existing…") { confirmExistingSync = true }
                Spacer()
                Button("Options") { model.showOptions() }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }.padding(14).frame(width: 480)
        .confirmationDialog("Queue existing captures without automatic clipboard copying?", isPresented: $confirmExistingSync) {
            Button("Sync existing") { model.syncExisting() }
            Button("Cancel", role: .cancel) {}
        }
    }
    private func rowColor(_ row: QueuedTransfer) -> Color {
        if row.phase == "ready" { return .green }
        if row.phase == "error" { return .orange }
        return .secondary
    }
    private func status(_ row: QueuedTransfer) -> String {
        switch row.phase {
        case "ready": return "OK"
        case "error": return "error"
        case "uploading", "verifying", "processing": return "uploading"
        default: return "queued"
        }
    }
    private func icon(_ row: QueuedTransfer) -> String {
        switch status(row) {
        case "OK": return "checkmark.circle.fill"
        case "error": return "exclamationmark.triangle.fill"
        case "uploading": return "arrow.up.circle"
        default: return "clock"
        }
    }
}
#endif
