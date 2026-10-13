import AppIntents
import SwiftUI
import HorizonCore
import IngestKit

// What an intent's answer shows beside its words in Siri and Shortcuts: the page's own type (a caps kicker, serif names,
// quiet details, the accent only for weight), on the system's own background so it reads in Siri's light and dark.
// Short by design (HIG: at most 400 points tall): a few rows, the rest in the app.

struct ItemsSnippet: View {
    let kicker: String
    let items: [ItemEntity]
    var empty: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Kicker(kicker)
            if items.isEmpty {
                Text(empty).font(.system(.body, design: .serif)).foregroundStyle(.secondary)
            }
            ForEach(items.prefix(5)) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle").foregroundStyle(item.isCompleted ? Design.accent : .secondary).imageScale(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.system(.headline, design: .serif)).lineLimit(2)
                        Text(Design.itemLine(course: item.list.isUnfiled ? nil : item.list.name, due: item.due, hasTime: item.dueDate?.hour != nil, weight: nil))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let weight = item.weight { Design.points(weight).font(.subheadline.weight(.semibold)) }
                }
            }
            if items.count > 5 { Text("And \(items.count - 5) more in Horizon").font(.caption).foregroundStyle(.secondary) }
        }
        .padding()
    }
}

/// A course's answer: the policies quoted, in the documents' own words, or the lines said about it.
struct CourseInfoSnippet: View {
    let course: String
    let lines: [String]
    let policies: [PolicySnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Kicker(course.uppercased())
            ForEach(lines, id: \.self) { line in
                Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(policies) { policy in
                VStack(alignment: .leading, spacing: 4) {
                    Text(PolicyLookup.name(policy.kind)).font(.system(.headline, design: .serif))
                    Text("“\(policy.text)”").font(.callout).lineLimit(8)   // the document's own words, quoted
                }
            }
        }
        .padding()
    }
}

struct CoverageSnippet: View {
    let stories: [CourseCoverage]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Kicker("COVERAGE")
            ForEach(stories.prefix(4)) { story in
                VStack(alignment: .leading, spacing: 3) {
                    Text(story.displayName).font(.system(.headline, design: .serif))
                    Text(story.findings.first ?? "Looks covered.").font(.callout).foregroundStyle(story.findings.isEmpty ? .secondary : .primary).lineLimit(2)
                }
            }
        }
        .padding()
    }
}

struct PlanSnippet: View {
    let blocks: [PlanBlock]
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Kicker("TODAY")
            if blocks.isEmpty { Text(note ?? "No plan yet.").font(.system(.body, design: .serif)).foregroundStyle(.secondary) }
            ForEach(blocks) { block in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(block.start.formatted(date: .omitted, time: .shortened)).font(.caption.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
                        .frame(minWidth: 58, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(block.title).font(.system(.headline, design: .serif)).lineLimit(1)
                        if !block.reason.isEmpty { Text(block.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
            }
        }
        .padding()
    }
}
