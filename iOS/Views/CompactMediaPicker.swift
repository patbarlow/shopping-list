import SwiftUI
import PhotosUI
@preconcurrency import AVFoundation

enum MediaPickerSource: String, Identifiable {
    case camera, photos
    var id: String { rawValue }
}

/// Our compact presentation around Apple's privacy-preserving embedded picker.
/// This grid does not require permission to browse the entire photo library.
struct CompactPhotoPicker: View {
    let onSelect: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: PhotosPickerItem?
    @State private var detent: PresentationDetent = .height(430)
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .automatic) {
                EmptyView()
            }
            .photosPickerStyle(.inline)
            .photosPickerAccessoryVisibility(detent == .large ? .visible : .hidden, edges: .top)
            .photosPickerAccessoryVisibility(.hidden, edges: .bottom)
            .ignoresSafeArea(edges: .bottom)
            .disabled(loading)

            HStack {
                Button { dismiss() } label: {
                    Image(hugeIcon: "chevron.left").frame(width: 48, height: 48)
                }.accessibilityLabel("Close photos")
                    .glassEffect(in: Circle())
                Spacer()
                Button { withAnimation { detent = detent == .large ? .height(430) : .large } } label: {
                    Text(detent == .large ? "Recents" : "All Photos")
                        .font(.headline).padding(.horizontal, 24).frame(height: 48)
                }.glassEffect(in: Capsule())
                    .accessibilityIdentifier("photos-expand")
            }
            .buttonStyle(.plain).padding(20)
            if loading { ProgressView().padding(20).background(.regularMaterial, in: Capsule()).frame(maxHeight: .infinity) }
        }
        .presentationDetents([.height(430), .large], selection: $detent)
        .presentationCornerRadius(36)
        .presentationDragIndicator(.hidden)
        .presentationBackground(TrolleyStyle.canvas)
        .alert("Couldn't open photo", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .task(id: selection) {
            guard let selection else { return }
            loading = true
            defer { loading = false }
            do {
                guard let data = try await selection.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                guard !Task.isCancelled else { return }
                onSelect(image)
                dismiss()
            } catch {
                if !Task.isCancelled { self.error = "Try choosing that photo again." }
            }
        }
    }
}

struct CompactCameraPicker: View {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var camera = CompactCameraSession()
    @State private var ready = false
    @State private var capturing = false
    @State private var error: String?
    @State private var denied = false

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session).ignoresSafeArea()
            if let error {
                VStack(spacing: 16) {
                    Image(hugeIcon: "camera").resizable().scaledToFit().frame(width: 42, height: 42)
                    Text(error).multilineTextAlignment(.center)
                    if denied {
                        Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                            .buttonStyle(.borderedProminent)
                    }
                }.padding(36).foregroundStyle(.white)
            } else if !ready { ProgressView().tint(.white) }
            VStack {
                Spacer()
                HStack {
                    Button { dismiss() } label: {
                        Image(hugeIcon: "chevron.left").frame(width: 48, height: 48)
                    }.accessibilityLabel("Close camera").glassEffect(.regular.tint(.black.opacity(0.25)), in: Circle())
                    Spacer()
                    Button {
                        capturing = true
                        camera.capture()
                    } label: {
                        ZStack {
                            Circle().strokeBorder(.white.opacity(0.85), lineWidth: 3).frame(width: 76, height: 76)
                            Circle().fill(.white).frame(width: 64, height: 64)
                            if capturing { ProgressView().tint(.black) }
                        }
                    }
                    .disabled(!ready || capturing)
                    .accessibilityLabel("Take photo").accessibilityIdentifier("camera-shutter")
                    Spacer()
                    Button { camera.flip() } label: {
                        Image(hugeIcon: "camera.rotate").frame(width: 48, height: 48)
                    }.disabled(!ready || capturing).accessibilityLabel("Switch camera")
                        .glassEffect(.regular.tint(.black.opacity(0.25)), in: Circle())
                }.buttonStyle(.plain).foregroundStyle(.white).padding(24)
            }
        }
        .background(.black)
        .presentationDetents([.height(480), .large])
        .presentationCornerRadius(36)
        .presentationDragIndicator(.hidden)
        .task {
            guard AVCaptureDevice.default(for: .video) != nil else {
                error = "The camera isn't available on this device."
                return
            }
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled else { return }
            guard allowed else {
                denied = AVCaptureDevice.authorizationStatus(for: .video) == .denied
                error = "Allow camera access to take a photo."
                return
            }
            camera.start { success in
                ready = success
                if !success { error = "The camera isn't available on this device." }
            } onPhoto: { image in
                capturing = false
                if let image { onCapture(image); dismiss() }
                else { error = "Couldn't take that photo. Close the camera and try again." }
            }
        }
        .onDisappear { camera.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.resume() } else { camera.pause() }
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ view: CameraPreviewView, context: Context) {}
}

private final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = preview.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
}

/// Capture configuration and blocking session calls stay on a serial queue.
/// The only public UI callbacks hop back to the main actor. No Photos writes.
private final class CompactCameraSession: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.patbarlow.trolley.camera")
    private let output = AVCapturePhotoOutput()
    private var active = false
    private var onPhoto: (@MainActor @Sendable (UIImage?) -> Void)?

    func start(onReady: @escaping @MainActor @Sendable (Bool) -> Void, onPhoto: @escaping @MainActor @Sendable (UIImage?) -> Void) {
        queue.async { [self] in
            active = true
            self.onPhoto = onPhoto
            session.beginConfiguration()
            session.sessionPreset = .photo
            let hasCamera = installCamera(.back)
            let hasOutput = session.canAddOutput(output)
            if hasOutput { session.addOutput(output) }
            let configured = hasCamera && hasOutput
            session.commitConfiguration()
            if configured { session.startRunning() }
            Task { @MainActor in onReady(configured) }
        }
    }

    private func installCamera(_ position: AVCaptureDevice.Position) -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return false }
        session.addInput(input)
        return true
    }

    func capture() {
        queue.async { [self] in
            guard active, let callback = onPhoto else { return }
            guard session.isRunning else {
                Task { @MainActor in callback(nil) }
                return
            }
            // This portrait-first capture matches the compact in-app preview.
            if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func flip() {
        queue.async { [self] in
            guard active, let old = session.inputs.first as? AVCaptureDeviceInput else { return }
            session.beginConfiguration()
            session.removeInput(old)
            if !installCamera(old.device.position == .back ? .front : .back), session.canAddInput(old) { session.addInput(old) }
            session.commitConfiguration()
        }
    }

    func pause() { queue.async { [self] in if session.isRunning { session.stopRunning() } } }
    func resume() { queue.async { [self] in if active, !session.inputs.isEmpty, !session.isRunning { session.startRunning() } } }
    func stop() {
        queue.async { [self] in
            active = false; onPhoto = nil
            if session.isRunning { session.stopRunning() }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = error == nil ? photo.fileDataRepresentation().flatMap(UIImage.init(data:)) : nil
        queue.async { [self] in
            guard active, let callback = onPhoto else { return }
            Task { @MainActor in callback(image) }
        }
    }
}
