import SwiftUI
import SwiftData
import HorizonCore
import IngestKit

struct CourseView: View {
    let course: Course

    private var obligations: [Obligation] { (course.obligations ?? []).filter { $0.deletedAt == nil }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) } }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(course.title).deck()
                    if let term = course.term { Text(term).foregroundStyle(.secondary) }
                    if let instructor = course.instructor { Text(instructor).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 4)
            }
            if !course.gradeComponents.isEmpty {
                Section("Grade") {
                    ForEach(course.gradeComponents, id: \.name) { component in
                        HStack { Text(component.name); Spacer(); Design.points(component.weight.map { $0 * 100 }).monospacedDigit() }
                    }
                }
            }
            Section("Obligations") {
                ForEach(obligations) { ObligationRow(obligation: $0) }
            }
            if let policies = course.policies, !policies.isEmpty {
                Section("Policies") {
                    ForEach(policies) { policy in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(policy.kind)).font(.caption).foregroundStyle(.secondary)
                            Text(policy.text)
                        }
                    }
                }
            }
        }
        .navigationTitle(course.code)
    }

    private func label(_ kind: PolicyKind) -> String {
        switch kind { case .lateWork: "Late work"; case .makeupExam: "Makeup exams"; case .attendance: "Attendance"; case .dropRule: "Drop rule"; case .extraCredit: "Extra credit"; case .other: "Policy" }
    }
}
