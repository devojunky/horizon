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
    static func file(from provider: NSItemProvider) async throws -> URL? {
        let temp = FileManager.default.temporaryDirectory
        for type in [UTType.pdf, .image, .fileURL, .plainText] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            let loaded = try await provider.loadItem(forTypeIdentifier: type.identifier)
            switch loaded {
            case let url as URL:
                if type == .fileURL || url.isFileURL {
                    guard let fileType = UTType(filenameExtension: url.pathExtension), readable.contains(where: { fileType.conforms(to: $0) }) else { continue }
                    let copy = temp.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.removeItem(at: copy)
                    try FileManager.default.copyItem(at: url, to: copy)
                    return copy
                }
            case let data as Data:
                let ext = type == .pdf ? "pdf" : type == .image ? "png" : "txt"
                let copy = temp.appendingPathComponent("shared-\(UUID().uuidString).\(ext)")
                try data.write(to: copy)
                return copy
            case let image as UIImage:
                guard let data = image.pngData() else { continue }
                let copy = temp.appendingPathComponent("screenshot-\(UUID().uuidString).png")
                try data.write(to: copy)
                return copy
            case let text as String:
                let copy = temp.appendingPathComponent("shared-\(UUID().uuidString).txt")
                try text.write(to: copy, atomically: true, encoding: .utf8)
                return copy
            default: continue
            }
        }
        return nil
    }
}
