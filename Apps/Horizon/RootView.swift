import SwiftUI
import SwiftData
import HorizonCore

/// The home screen is Coverage (SPEC §6.1). Intake status and the review queue sit above it; the strip and the day
/// plan arrive in M4 and M5.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Obligation.due) private var obligations: [Obligation]
    @Query(sort: \Course.code) private var courses: [Course]
    @State private var addingByHand = false
    @State private var linked: Obligation?

    private var live: [Obligation] { obligations.filter { $0.deletedAt == nil } }
    private var pending: [Obligation] { live.filter { $0.state == .pendingReview } }

    var body: some View {
        NavigationStack {
            List {
                if let reading = model.reading {
                    ReadingSection(reading: reading)
                } else if let status = model.statusLine ?? model.lastError {
                    Section { Label(status, systemImage: model.lastError == nil ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle").foregroundStyle(model.lastError == nil ? .secondary : Design.accent) }
                        .listRowSeparator(.hidden)
                }
                if !pending.isEmpty {
                    NavigationLink { ReviewView() } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(pending.count == 1 ? "One item to review" : "\(pending.count) items to review").font(.system(.title3, design: .serif, weight: .semibold))
                            Spacer()
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 4, trailing: 20))
                }
                CoverageList(reading: model.reading != nil)
            }
            .listStyle(.plain)
            .navigationTitle("Coverage")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) { ImportMenu() }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { Task { await model.drainAndSync() } } label: { Label("Sync with Reminders", systemImage: "arrow.triangle.2.circlepath") }
                        NavigationLink { DocumentsView() } label: { Label("Documents and usage", systemImage: "doc.text") }
                        Divider()
                        Button { addingByHand = true } label: { Label("Add by hand…", systemImage: "square.and.pencil") }
                        #if DEBUG
                        Divider()
                        Button {
                            if let sample = Bundle.main.url(forResource: "sample-syllabus", withExtension: "pdf") {
                                Task { await model.importFiles([sample]) }
                            }
                        } label: { Label("Ingest sample syllabus", systemImage: "ladybug") }
                        #endif
                    } label: { Label("More", systemImage: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $addingByHand) { ObligationEditor(mode: .manual, courses: courses) }
            .sheet(item: $linked) { ObligationEditor(mode: .review($0), courses: courses) }
            .onChange(of: model.linkedObligationID) { _, id in
                guard let id else { return }   // the reset below fires this again with nil; it must not close the sheet
                linked = live.first { $0.id == id }
                model.linkedObligationID = nil
            }
        }
    }
}

/// The document resolving into obligations, as the model streams them (SPEC §9's one earned animation, plainly for now).
struct ReadingSection: View {
    let reading: AppModel.Reading

    var body: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reading \(reading.filename)").font(.body.weight(.medium))
                    Text(progressLine).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            ForEach(reading.items) { item in
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                    Spacer()
                    Text(item.dateAsWritten ?? "…").foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.subheadline)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        } footer: {
            Text("Dates are checked against the document before anything is written to Reminders.")
        }
        .animation(.default, value: reading.items)
    }

    private var progressLine: String {
        let total = reading.chunks + reading.images
        let part = total > 1 ? "part \(min(max(reading.chunk, 1), total)) of \(total) · " : ""
        return part + "\(reading.items.count) found so far"
    }
}

struct ObligationRow: View {
    let obligation: Obligation

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(obligation.title).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    if let code = obligation.course?.code, !code.isEmpty { Text(code) }
                    Text(Design.due(obligation.due, hasTime: obligation.dueHasTime)).monospacedDigit()
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Design.points(obligation.pointsAtStake).font(.title3.weight(.semibold))
        }
        .padding(.vertical, 2)
    }
}
