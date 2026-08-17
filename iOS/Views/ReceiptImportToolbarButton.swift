import SwiftUI
import PhotosUI

/// Holds the "a scan is ready to review" state at the app root — instantiated
/// once in ShoppingListApp and handed down via `.environment(...)`, entirely
/// independent of any particular toolbar button's own lifecycle.
///
/// The scanner sheet used to be presented straight off `@State` living on
/// ReceiptImportToolbarButton itself. That looked fine in isolation, but that
/// button sits inside a `.toolbar { }` closure that recomputes on every
/// re-render of its host tab (list refetches, realtime reconnects, anything),
/// and evidence from real-device logs (repeated "glassEffect() tried to
/// update multiple times per frame" warnings right as a scan was in flight)
/// points at the button occasionally being torn down and rebuilt during that
/// churn — which tears down its `.sheet` and cancels the in-flight scan
/// request with it, right as ReceiptScannerView's own retry-proofing
/// (`hasStartedProcessing`) was making sure that first attempt couldn't just
/// quietly be retried by a second one anymore. Anchoring the state — and the
/// `.sheet` itself, in ShoppingListView — to something that isn't rebuilt by
/// that churn removes the failure mode instead of racing around it.
@MainActor
@Observable final class ReceiptImportCoordinator {
    var pendingCapture: ReceiptScannerView.InitialCapture? = nil
}

/// The "receipt" toolbar menu (Scan Receipt / Photo Library / Files) — shared
/// across every top-level tab so it appears in the same place everywhere, the
/// way the settings button does.
///
/// The native picker for the chosen source is triggered directly from here,
/// not from inside ReceiptScannerView — that way there's no intermediate
/// "choose a source" card that has to appear and then immediately get covered
/// by the real picker. ReceiptScannerView is only presented once real content
/// (a scanned page, photo, or PDF) is in hand, opening straight into its
/// scanning/reading state — from ShoppingListView, off the coordinator above,
/// not from here.
struct ReceiptImportToolbarButton: View {
    let householdId: String
    @Environment(ReceiptImportCoordinator.self) private var coordinator

    @State private var showDocumentScanner = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var selectedPhoto: PhotosPickerItem? = nil

    var body: some View {
        Menu {
            Button {
                showDocumentScanner = true
            } label: {
                Label("Scan Receipt", systemImage: "doc.viewfinder")
            }
            Button {
                showPhotoPicker = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }
            Button {
                showFilePicker = true
            } label: {
                Label("Files", systemImage: "folder")
            }
        } label: {
            Image(systemName: "receipt")
                .frame(width: 22, height: 22)
        }
        .fullScreenCover(isPresented: $showDocumentScanner) {
            DocumentScannerCapture { images in
                showDocumentScanner = false
                present(.images(images))
            } onCancel: {
                showDocumentScanner = false
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        .onChange(of: selectedPhoto) { _, item in
            // PhotosPicker's onChange is known to sometimes fire twice for a
            // single pick. Clearing the binding synchronously, before the
            // async load even starts, means a second firing for the same
            // pick sees nil and no-ops — without it, both firings raced to
            // load and present, tearing the first one down mid-request (its
            // now-cancelled network call surfaced as a flashed error) right
            // before the second took over and finished normally.
            guard let item else { return }
            selectedPhoto = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                present(.photoData(data))
            }
        }
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
