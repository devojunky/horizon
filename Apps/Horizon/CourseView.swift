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
    @State private var selected: UUID?   // macOS: the highlighted row; Delete removes it, double-click opens it
    @Environment(\.dismiss) private var dismiss

    private var obligations: [Obligation] { (course.obligations ?? []).filter { $0.deletedAt == nil }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) } }

    var body: some View {
        List(selection: $selected) {
            let detail = [course.code == course.displayName ? nil : course.code, course.term, course.instructor].compactMap { $0 }.filter { !$0.isEmpty }
            #if os(macOS)
            VStack(alignment: .leading, spacing: 10) {   // the window title is the page's; the course's own name heads the pane
                Text(course.displayName).display()
                if !detail.isEmpty { Text(detail.joined(separator: " · ")).foregroundStyle(.secondary) }
                HStack(spacing: 10) {
                    ImportMenu(courseID: course.id)
                    Button("Edit Course…") { editingCourse = true }
                }
                .padding(.top, 4)
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 12, trailing: 20))
            .selectionDisabled()
            #else
            if !detail.isEmpty {   // the title names the course; this line carries what else the document said
                Text(detail.joined(separator: " · ")).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 20))
                    .onPaper()
            }
            #endif
            if !course.gradeComponents.isEmpty {
                Section {
                    ForEach(course.gradeComponents, id: \.name) { component in
                        HStack { Text(component.name); Spacer(); Design.points(component.weight.map { $0 * 100 }).font(.body.weight(.semibold)) }
                    }
                } header: { Kicker("Grade") }
                .onPaper()
            }
            Section {
                ForEach(obligations) { item in
                    #if os(macOS)
                    ObligationRow(obligation: item, showCourse: false)
                        .tag(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { editing = item }
                        .contextMenu {
                            Button("Edit…") { editing = item }
                            Button("Delete", role: .destructive) { Task { await model.discard(item.id) } }
                        }
                        .accessibilityHint("Double-click to edit")
                    #else
                    Button { editing = item } label: { ObligationRow(obligation: item, showCourse: false) }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.discard(item.id) } }
                        }
                        .accessibilityHint("Opens the editor")
                    #endif
                }
                if obligations.isEmpty { Text("No items yet. Add a document, or an item by hand from the Coverage menu.").foregroundStyle(.secondary) }
            } header: { Kicker("Items") }
            .onPaper()
            if let policies = course.policies, !policies.isEmpty {
                Section {
                    ForEach(policies) { policy in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(policy.kind)).font(.caption).foregroundStyle(.secondary)
                            Text(policy.text)
                        }
                    }
                } header: { Kicker("Policies") }
                .onPaper()
            }
        }
        .listStyle(.plain)
        .paper()
        #if os(iOS)
        .navigationTitle(course.displayName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ImportMenu(courseID: course.id) }
            ToolbarItem(placement: .primaryAction) { Button("Edit") { editingCourse = true } }
        }
        #else
        .onDeleteCommand { if let id = selected { Task { await model.discard(id) }; selected = nil } }
        #endif
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
