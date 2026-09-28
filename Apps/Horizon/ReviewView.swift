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
                EditorialEmpty(title: "Nothing to review.", deck: "Everything the parser found was sure enough to go straight to Reminders.") { EmptyView() }
                    .listRowSeparator(.hidden)
                    .onPaper()
            }
            ForEach(pending) { item in
                VStack(alignment: .leading, spacing: 8) {
                    ObligationRow(obligation: item)
                    Text(item.reviewReason).font(.footnote).foregroundStyle(item.changeNote == nil ? .secondary : Design.accent)
                    HStack {
                        Button("Confirm", systemImage: "checkmark") { Task { await model.confirm(item.id) } }.buttonStyle(.bordered).tint(Design.accent)
                        Button("Edit") { editing = item }.buttonStyle(.bordered)
                        Spacer()
                        Button("Discard", role: .destructive) { Task { await model.discard(item.id) } }.buttonStyle(.borderless)
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
                .onPaper()
                .swipeActions(edge: .leading) { Button("Confirm", systemImage: "checkmark") { Task { await model.confirm(item.id) } }.tint(Design.accent) }
                .swipeActions(edge: .trailing) { Button("Discard", systemImage: "trash", role: .destructive) { Task { await model.discard(item.id) } } }
            }
        }
        .listStyle(.plain)
        .paper()
        .navigationTitle("Review")
        .sheet(item: $editing) { ObligationEditor(mode: .review($0), courses: courses) }
    }
}
#endif

extension Obligation {
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
