import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
#if os(iOS)
import VisionKit
import UIKit
#endif

/// Where documents come from inside the app: Files, the photo library, and (on iPhone/iPad) the document camera.
/// Each source ends the same way: temporary files handed to `AppModel.importFiles`. Given more of a page's actions, it
/// is that page's More menu, the sources first under "Add Document" (iOS's course page: one button in the bar leaves
/// its title the room to sit centred).
struct ImportMenu<More: View>: View {
    /// Files what is imported under this course (the course page); nil lets the parser find the course.
    var courseID: UUID? = nil
    private let more: More?
    @State private var files = false
    @State private var photos: ImportPickers.Photos?
    @State private var scanning = false

    #if os(macOS)
    static var readable: [UTType] { [.pdf, .image, .plainText, UTType("org.openxmlformats.wordprocessingml.document")].compactMap { $0 } }
    #else
    static var readable: [UTType] { [.pdf, .image, .plainText] }   // Word is read on a Mac only (AppKit's converter): not offered here
    #endif

    init(courseID: UUID? = nil) where More == EmptyView { self.courseID = courseID; more = nil }
    init(courseID: UUID? = nil, @ViewBuilder more: () -> More) { self.courseID = courseID; self.more = more() }

    var body: some View {
        Menu {
            if let more {
                Section("Add Document") { sources }
                Section { more }
            } else {
                sources
            }
        } label: {
            if more == nil { Label("Add Document", systemImage: "doc.badge.plus") } else { Label("More", systemImage: "ellipsis.circle") }
        }
        .modifier(ImportPickers(courseID: courseID, files: $files, photos: $photos, scanning: $scanning))
    }

    @ViewBuilder private var sources: some View {
        Button { files = true } label: { Label("Files…", systemImage: "folder") }
        Button { photos = .images } label: { Label("Photo Library…", systemImage: "photo.on.rectangle") }
        #if os(iOS)
        if VNDocumentCameraViewController.isSupported {
            Button { scanning = true } label: { Label("Scan with Camera", systemImage: "doc.viewfinder") }
        }
        #endif
    }
}

/// The three ways a document comes in (Files, Photos, the document camera), each ending in temporary files handed to
/// `AppModel.importFiles`. The Add Document menus present them, and so does the app itself when asked to take a
/// document (a control's one tap, a shortcut: `AppDestination.importDocument`), Photos then showing screenshots only.
struct ImportPickers: ViewModifier {
    enum Photos: Equatable { case images, screenshots }

    var courseID: UUID?
    @Binding var files: Bool
    @Binding var photos: Photos?
    @Binding var scanning: Bool
    @Environment(AppModel.self) private var model
    @State private var picked: [PhotosPickerItem] = []
    @State private var scanFailed = false

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $files, allowedContentTypes: ImportMenu<EmptyView>.readable, allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { Task { await model.importFiles(urls, courseID: courseID) } }
            }
            .photosPicker(isPresented: Binding(get: { photos != nil }, set: { if !$0 { photos = nil } }), selection: $picked, maxSelectionCount: 10,
                          matching: photos == .screenshots ? .screenshots : .images)
            .onChange(of: picked) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    var urls: [URL] = []
                    var unreadable = 0
                    for item in items {
                        guard let data = try? await item.loadTransferable(type: Data.self) else { unreadable += 1; continue }
                        let stamp = Date().formatted(.dateTime.month(.abbreviated).day().hour().minute()).replacingOccurrences(of: ":", with: ".")
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Photo \(stamp) \(urls.count + 1).\(Self.imageExtension(data))")
                        do { try data.write(to: url); urls.append(url) } catch { unreadable += 1 }
                    }
                    picked = []
                    await model.importFiles(urls, courseID: courseID)
                    for url in urls { try? FileManager.default.removeItem(at: url) }   // the app keeps its own copy
                    if unreadable > 0 { model.lastError = unreadable == 1 ? "One photo could not be read." : "\(unreadable) photos could not be read." }
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $scanning, onDismiss: { scanFailed = false }) {
                DocumentCamera { url in
                    scanning = false
                    if let url {
                        Task { await model.importFiles([url], courseID: courseID); try? FileManager.default.removeItem(at: url) }
                    } else if scanFailed {
                        model.lastError = "The scan could not be saved."
                    }
                } failed: { scanFailed = true }
                .ignoresSafeArea()
            }
            #endif
    }

    private static func imageExtension(_ data: Data) -> String {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : data.starts(with: [0xFF, 0xD8]) ? "jpg" : "heic"
    }
}

#if os(iOS)
/// VisionKit's document scanner: multi-page, auto-cropped. Pages become one image-only PDF, which the normalizer
/// treats like any scanned document (each page a picture, which Claude transcribes first so the guards have text to check).
struct DocumentCamera: UIViewControllerRepresentable {
    let completion: (URL?) -> Void
    var failed: () -> Void = {}

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion, failed: failed) }

    @MainActor final class Coordinator: NSObject, @MainActor VNDocumentCameraViewControllerDelegate {   // VisionKit calls its delegate on the main thread
        let completion: (URL?) -> Void
        let failed: () -> Void
        init(completion: @escaping (URL?) -> Void, failed: @escaping () -> Void) { self.completion = completion; self.failed = failed }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            // Drawing full-resolution pages into a PDF takes seconds for a multi-page scan; keep it off the main thread.
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            Task.detached(priority: .userInitiated) { [weak self] in
                let url = Self.pdf(pages: pages)
                await MainActor.run {
                    if url == nil { self?.failed() }   // drawn into nothing: said, not lost
                    self?.completion(url)
                }
            }
        }

        nonisolated static func pdf(pages: [UIImage]) -> URL? {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString).pdf")
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let consumer = CGDataConsumer(url: url as CFURL), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
            for page in pages {
                guard let image = page.cgImage else { continue }
                let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
                let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                pdf.beginPDFPage(nil)
                pdf.draw(image, in: CGRect(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2, width: size.width, height: size.height))
                pdf.endPDFPage()
            }
            pdf.closePDF()
            return url
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { completion(nil) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: any Error) { failed(); completion(nil) }
    }
}
#endif
