import SwiftUI
import SwiftData
import HorizonCore

#if os(iOS)
/// SPEC §4.1 step 6: one screen, one tap. Confirm as parsed, fix a field, or discard. (The Mac's is a table with the
/// same three actions on a selection: `MacReviewPage`.)
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Obligation.due) private var obligations: [Obligation]
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    @State private var editing: Obligation?

    private var pending: [Obligation] { obligations.filter { $0.deletedAt == nil && $0.state == .pendingReview && $0.completedAt == nil } }   // done needs no review

    var body: some View {
        List {
            if pending.isEmpty {
                EditorialEmpty(title: "Nothing to review.", deck: "Everything the reader found was sure enough to go straight to Reminders.") { EmptyView() }
                    .listRowSeparator(.hidden)
                    .onPaper()
            }
            ForEach(pending) { item in
                VStack(alignment: .leading, spacing: 8) {
                    ObligationRow(obligation: item)
                    Text(item.reviewReason).font(.footnote).foregroundStyle(item.changeNote == nil ? .secondary : Design.accentInk)
                    // One row of actions while they fit; stacked at the largest sizes, never a word broken in a capsule.
                    ViewThatFits(in: .horizontal) {
                        HStack { actions(item, inRow: true) }
                        VStack(alignment: .leading, spacing: 10) { actions(item, inRow: false) }
                    }
                    .controlSize(.small)
                    .lineLimit(1)
                }
                .padding(.vertical, 4)
                .onPaper()
                .swipeActions(edge: .leading) { AccentSwipe("Confirm", systemImage: "checkmark") { Task { await model.confirm(item.id) } } }
                .swipeActions(edge: .trailing) {
                    if item.otherDate == nil { Button("Discard", systemImage: "trash", role: .destructive) { Task { await model.discard(item.id) } } }
                }
            }
        }
        .listStyle(.plain)
        .paper()
        .animation(.default, value: pending.map(\.id))   // a confirmed or discarded item leaves its row animated, the rest close up
        .navigationTitle("Review")
        .sheet(item: $editing) { ObligationEditor(mode: .review($0), courses: courses) }
    }

    /// Confirm, the other date when a document changed it, Edit, and Discard (for an item that is not a change: there,
    /// discarding would delete the item itself).
    @ViewBuilder private func actions(_ item: Obligation, inRow: Bool) -> some View {
        Button("Confirm", systemImage: "checkmark") { Task { await model.confirm(item.id) } }.bordered().reachable()
        if let earlier = item.otherDate {
            Button("Use \(earlier.formatted(.dateTime.month(.abbreviated).day()))") { Task { await model.confirm(item.id, edits: ObligationEdits(due: .some(earlier))) } }.bordered().reachable()
        }
        Button("Edit") { editing = item }.bordered().reachable()
        if inRow { Spacer() }
        if item.otherDate == nil {
            Button("Discard", role: .destructive) { Task { await model.discard(item.id) } }.buttonStyle(.borderless).reachable()
        }
    }
}
#endif

extension Obligation {
    /// The other date when a read changed this one or disagrees with the user's: the earlier date a document moved, or
    /// the document's new one beside a date the user set. Review offers it as the alternative to confirming.
    var otherDate: Date? { changeNote == nil ? nil : conflictingDate }

    /// Why an item waits for review, in a line: what the date was read as, what the guards found, and how sure the
    /// reader was; or what a later read changed (`changeNote`).
    var reviewReason: String {
        if let note = changeNote { return note }
        var parts: [String] = []
        if let written = dateAsWritten, !written.isEmpty { parts.append("Read as “\(written)”") }
        let found = reviewFlags
        if !found.isEmpty { parts.append(found.joined(separator: ", ")) }
        parts.append("Confidence \(Int((confidence * 100).rounded()))%")
        return parts.joined(separator: " · ")
    }

    /// What the guards found, in words.
    var reviewFlags: [String] {
        flags.compactMap { flag -> String? in
            switch flag {
            case "dateNotInSource": "date not found in the document"
            case "dateDisagreement": "two readings of the date"
            case "dateAmbiguous": "another date on the same line"
            case "dateUnresolved": "date could not be read"
            case "conflictingDate": "appears twice with different dates"
            case "unknownComponent": "grade component unknown"
            case "titleNotInSource": "the document never names it this way"
            case "titleFromLine": "name taken from the sentence with the date"
            case "dateNotOnRow": "the date isn't on the item's own line"
            case "modelLowConfidence": "low confidence"
            default: nil
            }
        }
    }
}
