import SwiftUI

/// The chrome of an editing sheet, as each platform expects it. iOS: the title and Cancel / Save in the navigation
/// bar. macOS: the title at the top of the sheet and the buttons in a bar at its foot, Cancel leading and the default
/// action trailing, with Escape and Return bound to them.
struct EditorChrome: ViewModifier {
    let title: String
    let confirmTitle: String
    let confirmDisabled: Bool
    /// Something was changed: Cancel (and Escape) asks before throwing it away, from the Cancel button itself, so on
    /// iOS the question points at what was pressed rather than floating over the form.
    var dirty = false
    let cancel: () -> Void
    let confirm: () -> Void
    @State private var confirmingDiscard = false

    private func tryCancel() { if dirty { confirmingDiscard = true } else { cancel() } }

    private func cancelButton() -> some View {
        Button(action: tryCancel) {
            #if os(iOS)
            BarLabel("Cancel", systemImage: "xmark")   // on iPhone Duo's side bar, Close's own symbol, at the top of it
            #else
            Text("Cancel")
            #endif
        }
            .confirmationDialog("Discard changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive, action: cancel)
                Button("Keep Editing", role: .cancel) {}
            }
    }

    func body(content: Content) -> some View {
        #if os(iOS)
        // On iPhone Duo's outer display the sheet's bar stands at its side: Cancel and the confirming action become
        // symbols so the bar can (Close at the top, then the action under it), and the form has the display's height,
        // which the keyboard halves.
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { cancelButton() }
                ToolbarItem(placement: .confirmationAction) { Button(action: confirm) { BarLabel(confirmTitle, systemImage: "checkmark") }.disabled(confirmDisabled) }
            }
        #else
        content
            .formStyle(.grouped)   // scrolls, and lays a field beside its label; the columns style would size the sheet to the whole form
            .navigationTitle(title)   // the sheet's own bar shows it
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 12) {
                    Spacer()
                    cancelButton().keyboardShortcut(.cancelAction)
                    Button(confirmTitle, action: confirm).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(confirmDisabled)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(.bar)
            }
            .modifier(EscapeCancels(cancel: tryCancel))
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
    /// What Cancel does now. The monitor lives as long as the sheet, so it calls through this, set at every evaluation:
    /// a closure kept from the sheet's opening would see it unchanged for ever, and Escape closed an edited sheet unasked.
    @State private var current = Current()
    final class Current { var cancel: () -> Void = {} }

    func body(content: Content) -> some View {
        current.cancel = cancel
        return content
            .background(WindowFinder { window = $0 })
            .onAppear {
                let current = current
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.keyCode == 53, event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),   // Escape alone
                          let window, event.window === window,
                          !((window.firstResponder as? NSTextView)?.hasMarkedText() ?? false) else { return event }
                    current.cancel()
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

    func editorChrome(title: String, confirm: String, disabled: Bool, dirty: Bool = false, cancel: @escaping () -> Void, action: @escaping () -> Void) -> some View {
        modifier(EditorChrome(title: title, confirmTitle: confirm, confirmDisabled: disabled, dirty: dirty, cancel: cancel, confirm: action))
    }
}

/// A page's own navigation stack on iOS (its title bar, its pushes, on `path` when the page keeps one); on macOS the
/// page sits in the window's detail column, whose toolbar and title it uses.
struct PageStack<Content: View>: View {
    var path: Binding<[Route]>?
    var content: Content

    init(path: Binding<[Route]>? = nil, @ViewBuilder content: () -> Content) {
        self.path = path; self.content = content()
    }

    var body: some View {
        #if os(iOS)
        if let path { NavigationStack(path: path) { content } } else { NavigationStack { content } }
        #else
        content
        #endif
    }
}

/// A labelled text field in an editor: the label and the value on one line, the value trailing; at the accessibility
/// sizes the label above and the value under it, wrapping, so the value (the thing being edited) is read whole.
struct FieldRow: View {
    let label: String
    let prompt: String
    @Binding var text: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                TextField(prompt, text: $text, axis: .vertical)
            }
        } else {
            LabeledContent(label) { TextField(prompt, text: $text).multilineTextAlignment(.trailing).promptOnly() }
        }
    }
}

extension View {
    /// A picker whose choices are long names (courses): at the accessibility sizes on iOS a list of its own, where each
    /// name is whole, rather than a menu whose value is cut in the row.
    @ViewBuilder func choosesInList(_ large: Bool) -> some View {
        #if os(iOS)
        if large { pickerStyle(.navigationLink) } else { self }
        #else
        self
        #endif
    }
}
