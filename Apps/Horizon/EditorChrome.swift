import SwiftUI

/// The chrome of an editing sheet, as each platform expects it. iOS: the title and Cancel / Save in the navigation
/// bar. macOS: the title at the top of the sheet and the buttons in a bar at its foot, Cancel leading and the default
/// action trailing, with Escape and Return bound to them.
struct EditorChrome: ViewModifier {
    let title: String
    let confirmTitle: String
    let confirmDisabled: Bool
    let cancel: () -> Void
    let confirm: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) { Button(confirmTitle, action: confirm).disabled(confirmDisabled) }
            }
        #else
        content
            .formStyle(.grouped)   // scrolls, and lays a field beside its label; the columns style would size the sheet to the whole form
            .navigationTitle(title)   // the sheet's own bar shows it
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 12) {
                    Spacer()
                    Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                    Button(confirmTitle, action: confirm).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(confirmDisabled)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(.bar)
            }
        #endif
    }
}

extension View {
    /// A text field's title is its placeholder on iOS and its form label on macOS; beside a `LabeledContent` label
    /// the latter doubles up, so on the Mac the field keeps only its prompt.
    func promptOnly() -> some View {
        #if os(macOS)
        labelsHidden()
        #else
        self
        #endif
    }

    func editorChrome(title: String, confirm: String, disabled: Bool, cancel: @escaping () -> Void, action: @escaping () -> Void) -> some View {
        modifier(EditorChrome(title: title, confirmTitle: confirm, confirmDisabled: disabled, cancel: cancel, confirm: action))
    }
}

/// A page's own navigation stack on iOS (its title bar, its pushes); on macOS the page sits in the window's detail
/// column, whose toolbar and title it uses.
struct PageStack<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        #if os(iOS)
        NavigationStack { content }
        #else
        content
        #endif
    }
}
