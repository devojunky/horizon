import SwiftUI
import SwiftData
import HorizonCore

/// SPEC §4.3: a small debug view showing token counts, per document.
struct DocumentsView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \SourceDocument.queuedAt, order: .reverse) private var documents: [SourceDocument]

    var body: some View {
        List {
            Section {
                LabeledContent("Reminders access", value: model.remindersAuthorized.map { $0 ? "Granted" : "Denied" } ?? "Not asked")
                LabeledContent("Device", value: AppModel.deviceName)
            }
            Section("Documents") {
                ForEach(documents) { doc in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(doc.filename).font(.body.weight(.medium))
                        Text("\(status(doc)) · \(doc.deviceName) · \(doc.queuedAt.formatted(date: .abbreviated, time: .shortened))").font(.footnote).foregroundStyle(.secondary)
                        if doc.status == .parsed {
                            Text("\(doc.inputTokens) in · \(doc.outputTokens) out · \(doc.durationMs / 1000) s · \(doc.route ?? "")").font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                        }
                        if let failure = doc.failure { Text(failure).font(.footnote).foregroundStyle(Design.accent) }
                        if doc.status == .failed || doc.status == .awaitingCloudParse {
                            Button("Retry") { Task { await model.retry(documentID: doc.id) } }.font(.footnote).buttonStyle(.bordered).controlSize(.mini)
                        }
                        ForEach(doc.warnings, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle("Documents")
    }

    private func status(_ doc: SourceDocument) -> String {
        switch doc.status { case .queued: "Queued"; case .parsed: "Parsed"; case .failed: "Failed"; case .awaitingCloudParse: "Waiting for Private Cloud Compute" }
    }
}
