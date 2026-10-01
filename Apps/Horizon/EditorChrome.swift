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
            .modifier(EscapeCancels(cancel: cancel))
        #endif
    }
}

#if os(macOS)
/// Escape cancels the sheet from anywhere in it. A text or date field keeps the key for itself (a text field's editor
/// takes it for word completion), so Cancel's own shortcut never hears it while one has the keyboard, and in an editor
/// one always does: the first field takes it as the sheet opens. Only this sheet's window is watched (a popover or an
/// alert over it has its own Escape), and a composition in progress keeps its Escape, which cancels the marked text.
private struct EscapeCancels: ViewModifier {
    let cancel: () -> Void
    @State private var window: NSWindow?
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .background(WindowFinder { window = $0 })
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.keyCode == 53, event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),   // Escape alone
                          let window, event.window === window,
                          !((window.firstResponder as? NSTextView)?.hasMarkedText() ?? false) else { return event }
                    cancel()
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

/// Reports the window a view is put in.
private struct WindowFinder: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { Probe(found: found) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        let found: (NSWindow?) -> Void
        init(found: @escaping (NSWindow?) -> Void) { self.found = found; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            DispatchQueue.main.async { self.found(window) }   // outside the view update that put it there
        }
    }
}
#endif

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
