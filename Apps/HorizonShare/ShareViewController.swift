import UIKit
import SwiftUI
import UniformTypeIdentifiers
import SwiftData
import HorizonCore

/// Share sheet entry (SPEC §4.1). Copies what was shared into the App Group inbox and records it; the app parses it next
/// time it runs (or in the background). Nothing is parsed here, so the sheet closes in a second.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let host = UIHostingController(rootView: ShareView(context: extensionContext).tint(ShareView.accent))
        host.view.backgroundColor = .systemBackground
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

struct ShareView: View {
    /// Same accent as the app (Design.accent); the extension has no access to the app target.
    static let accent = Color(red: 1.0, green: 0.68, blue: 0.26)
    let context: NSExtensionContext?
    @State private var message = "Adding to Horizon…"
    @State private var done = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: done ? "checkmark.circle" : "doc.text.magnifyingglass").font(.system(size: 40)).foregroundStyle(.tint)
            Text(message).multilineTextAlignment(.center)
            if done { Button("Done") { context?.completeRequest(returningItems: nil) }.buttonStyle(.borderedProminent) }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await enqueue() }
    }

    private func enqueue() async {
        do {
            let container = try HorizonContainer.shared()
            let store = HorizonStore(modelContainer: container)
            let coordinator = IngestCoordinator(store: store, storage: DocumentStorage.appGroup() ?? .temporary(), sync: nil, deviceName: UIDevice.current.name)
            var count = 0
            for item in context?.inputItems as? [NSExtensionItem] ?? [] {
                for provider in item.attachments ?? [] {
                    if let url = try await Self.file(from: provider) {
                        _ = try await coordinator.enqueue(fileURL: url)
                        count += 1
                    }
                }
            }
            message = count == 0 ? "Nothing Horizon can read was shared." : "Queued \(count == 1 ? "1 document" : "\(count) documents"). Open Horizon to parse it into Reminders."
        } catch {
            message = "Could not add this: \(error.localizedDescription)"
        }
        done = true
    }

    static let readable: [UTType] = [.pdf, .image, .plainText, UTType("org.openxmlformats.wordprocessingml.document")].compactMap { $0 }

    /// PDFs, images, text and readable files become a temporary file the coordinator can copy in. Anything else is skipped.
    /// Each kind is asked for the way it is held: a file the host points at comes as its URL (its own name kept), text as
    /// bytes, and a PDF or an image as a file representation, however the host has it (a file, data, a UIImage).
    static func file(from provider: NSItemProvider) async throws -> URL? {
        let temp = FileManager.default.temporaryDirectory
        for type in [UTType.pdf, .image, .fileURL, .plainText] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            switch type {
            case .fileURL:
                guard let url = try await load({ provider.loadObject(ofClass: URL.self, completionHandler: $0) }), url.isFileURL,
                      let fileType = UTType(filenameExtension: url.pathExtension), readable.contains(where: { fileType.conforms(to: $0) }) else { continue }
                let copy = temp.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: copy)
                try FileManager.default.copyItem(at: url, to: copy)
                return copy
            case .plainText:
                guard let data = try await load({ provider.loadDataRepresentation(forTypeIdentifier: type.identifier, completionHandler: $0) }) else { continue }
                let copy = temp.appendingPathComponent("shared-\(UUID().uuidString).txt")
                try text(in: data).write(to: copy)
                return copy
            default:
                // The representation's file lives only until the handler returns, so the copy is made inside it.
                return try await withCheckedThrowingContinuation { continuation in
                    _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                        guard let url else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)); return }
                        let copy = temp.appendingPathComponent(url.lastPathComponent)
                        try? FileManager.default.removeItem(at: copy)
                        continuation.resume(with: Result { try FileManager.default.copyItem(at: url, to: copy); return copy })
                    }
                }
            }
        }
        return nil
    }

    /// One of the provider's completion-handler loaders as an async call: what it loaded, or nil when it had nothing.
    private static func load<T: Sendable>(_ start: (@escaping @Sendable (T?, (any Error)?) -> Void) -> Progress) async throws -> T? {
        try await withCheckedThrowingContinuation { continuation in
            _ = start { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: value) }
            }
        }
    }

    /// The bytes to write for a text item: a host still on the pre-iOS 11 item API hands its NSString over as a keyed
    /// archive, which is unwrapped; anything else (a string object, a text file) is the text itself.
    private static func text(in data: Data) -> Data {
        guard data.starts(with: "bplist00".utf8), let string = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSString.self, from: data) else { return data }
        return Data((string as String).utf8)
    }
}
