import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
#if os(iOS)
import VisionKit
import UIKit
#endif

/// Where documents come from inside the app: Files, the photo library, and (on iPhone/iPad) the document camera.
/// Each source ends the same way: temporary files handed to `AppModel.importFiles`.
struct ImportMenu: View {
    @Environment(AppModel.self) private var model
    @State private var files = false
    @State private var choosingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var scanning = false

    static let readable: [UTType] = [.pdf, .image, .plainText, UTType("org.openxmlformats.wordprocessingml.document")].compactMap { $0 }

    var body: some View {
        Menu {
            Button { files = true } label: { Label("Files…", systemImage: "folder") }
            Button { choosingPhotos = true } label: { Label("Photo Library…", systemImage: "photo.on.rectangle") }
            #if os(iOS)
            if VNDocumentCameraViewController.isSupported {
                Button { scanning = true } label: { Label("Scan with Camera", systemImage: "doc.viewfinder") }
            }
            #endif
        } label: {
            Label("Ingest document", systemImage: "doc.badge.plus")
        }
        .fileImporter(isPresented: $files, allowedContentTypes: Self.readable, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await model.importFiles(urls) } }
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $photos, maxSelectionCount: 10, matching: .images)
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var urls: [URL] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let stamp = Date().formatted(.dateTime.month(.abbreviated).day().hour().minute()).replacingOccurrences(of: ":", with: ".")
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Photo \(stamp) \(urls.count + 1).\(Self.imageExtension(data))")
                        try? data.write(to: url)
                        urls.append(url)
                    }
                }
                photos = []
                await model.importFiles(urls)
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $scanning) {
            DocumentCamera { url in
                scanning = false
                if let url { Task { await model.importFiles([url]) } }
            }
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
/// treats like any scanned document (Vision OCR text for the guards, the image itself for the model).
struct DocumentCamera: UIViewControllerRepresentable {
    let completion: (URL?) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completion: (URL?) -> Void
        init(completion: @escaping (URL?) -> Void) { self.completion = completion }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString).pdf")
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let consumer = CGDataConsumer(url: url as CFURL), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { completion(nil); return }
            for page in 0..<scan.pageCount {
                guard let image = scan.imageOfPage(at: page).cgImage else { continue }
                let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
                let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                pdf.beginPDFPage(nil)
                pdf.draw(image, in: CGRect(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2, width: size.width, height: size.height))
                pdf.endPDFPage()
            }
            pdf.closePDF()
            completion(url)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { completion(nil) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: any Error) { completion(nil) }
    }
}
#endif
