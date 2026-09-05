import SwiftUI
import SwiftData
import HorizonCore
import IngestKit

struct CourseView: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Course> { $0.deletedAt == nil }, sort: \Course.code) private var courses: [Course]
    let course: Course
    @State private var editing: Obligation?
    @State private var editingCourse = false
    @Environment(\.dismiss) private var dismiss

    private var obligations: [Obligation] { (course.obligations ?? []).filter { $0.deletedAt == nil }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) } }

    var body: some View {
        List {
            let detail = [course.code == course.displayName ? nil : course.code, course.term, course.instructor].compactMap { $0 }.filter { !$0.isEmpty }
            if !detail.isEmpty {   // the title names the course; this line carries what else the document said
                Section { Text(detail.joined(separator: " · ")).foregroundStyle(.secondary) }
            }
            if !course.gradeComponents.isEmpty {
                Section("Grade") {
                    ForEach(course.gradeComponents, id: \.name) { component in
                        HStack { Text(component.name); Spacer(); Design.points(component.weight.map { $0 * 100 }).monospacedDigit() }
                    }
                }
            }
            Section("Obligations") {
                ForEach(obligations) { item in
                    Button { editing = item } label: { ObligationRow(obligation: item, showCourse: false) }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.discard(item.id) } }
                        }
                        .accessibilityHint("Opens the editor")
                }
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
        .navigationTitle(course.displayName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ImportMenu(courseID: course.id) }
            ToolbarItem(placement: .primaryAction) { Button("Edit") { editingCourse = true } }
        }
        .sheet(item: $editing) { ObligationEditor(mode: .edit($0), courses: courses) }
        .sheet(isPresented: $editingCourse) { CourseEditor(course: course) }
        .onChange(of: course.deletedAt) { _, gone in if gone != nil { dismiss() } }
        .onAppear {
            if MainTabs.debugFlag("--open-item") { editing = obligations.first }
            if MainTabs.debugFlag("--open-course-editor") { editingCourse = true }
        }
    }

    private func label(_ kind: PolicyKind) -> String {
        switch kind { case .lateWork: "Late work"; case .makeupExam: "Makeup exams"; case .attendance: "Attendance"; case .dropRule: "Drop rule"; case .extraCredit: "Extra credit"; case .other: "Policy" }
    }
}
