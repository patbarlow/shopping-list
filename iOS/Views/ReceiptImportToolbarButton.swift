import SwiftUI
import PhotosUI

/// Media and receipt review presentation live at the app root, so toolbar
/// rebuilds or tab changes cannot cancel a capture or an in-flight import.
@MainActor
@Observable final class ReceiptImportCoordinator {
    var pendingCapture: ReceiptScannerView.InitialCapture?
    var mediaPicker: MediaPickerSource?
    private var queuedCapture: ReceiptScannerView.InitialCapture?

    func finishMedia(_ image: UIImage) {
        guard pendingCapture == nil, queuedCapture == nil else { return }
        queuedCapture = .images([image])
        mediaPicker = nil
    }

    func presentQueuedCapture() {
        guard pendingCapture == nil else { queuedCapture = nil; return }
        pendingCapture = queuedCapture
        queuedCapture = nil
    }
}

struct ReceiptImportToolbarButton: View {
    let householdId: String
    @Environment(ReceiptImportCoordinator.self) private var coordinator

    @State private var showFilePicker = false

    var body: some View {
        Menu {
            Button {
                coordinator.mediaPicker = .camera
            } label: {
                Label("Scan Receipt", hugeIcon: "doc.viewfinder")
            }
            Button {
                coordinator.mediaPicker = .photos
            } label: {
                Label("Photo Library", hugeIcon: "photo.on.rectangle")
            }
            Button {
                showFilePicker = true
            } label: {
                Label("Files", hugeIcon: "folder")
            }
        } label: {
            Image(hugeIcon: "receipt")
                .frame(width: 22, height: 22)
        }
        .accessibilityLabel("Import receipt")
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            if let data = try? Data(contentsOf: url) {
                present(.pdfData(data))
            }
        }
    }

    private func present(_ capture: ReceiptScannerView.InitialCapture) {
        // A second capture arriving while one's already up/pending — from any
        // of the three sources, not just the photo picker's known double-fire
        // — must never overwrite it: that's exactly what tore down a
        // still-scanning ReceiptScannerView and replaced it mid-request.
        guard coordinator.pendingCapture == nil else { return }
        // The picker we just got this from (camera, photo library, or files)
        // is still mid-dismissal at this point — presenting the new sheet in
        // the same beat races it against that dismissal on the same
        // presenting controller, and losing that race is what showed up as
        // an empty white card that never filled in. Waiting a beat lets the
        // dismissal actually finish first.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard coordinator.pendingCapture == nil else { return }
            coordinator.pendingCapture = capture
        }
    }
}
