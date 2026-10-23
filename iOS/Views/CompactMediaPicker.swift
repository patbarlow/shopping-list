import SwiftUI
import PhotosUI
import Vision
import CoreImage.CIFilterBuiltins
@preconcurrency import AVFoundation

enum MediaPickerSource: String, Identifiable {
    case camera, photos, scan
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
                Button { AppHaptics.tap(); dismiss() } label: {
                    Image(hugeIcon: "chevron.left").frame(width: 48, height: 48)
                }.accessibilityLabel("Close photos")
                    .glassEffect(in: Circle())
                Spacer()
                Button { AppHaptics.selection(); withAnimation { detent = detent == .large ? .height(430) : .large } } label: {
                    Text(detent == .large ? "Recents" : "All Photos")
                        .font(.headline).padding(.horizontal, 24).frame(height: 48)
                }.glassEffect(in: Capsule())
                    .accessibilityIdentifier("photos-expand")
            }
            .buttonStyle(.plain).padding(20)
            if loading { ProgressView().padding(20).background(.regularMaterial, in: Capsule()).frame(maxHeight: .infinity) }
        }
        // One permitted height at a time: dragging the grid always scrolls it.
        // Only All Photos/Recents changes the presentation height.
        .presentationDetents([detent], selection: $detent)
        .presentationContentInteraction(.scrolls)
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

/// The same capture surface serves a quick price photo and a receipt scan.
struct CompactCameraPicker: View {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var camera = CompactCameraSession()
    @State private var ready = false
    @State private var capturing = false
    @State private var error: String?
    @State private var denied = false
    @State private var optionsOpen = false
    @State private var scan: Bool
    @State private var flash = CameraFlash.off

    init(scan: Bool = false, onCapture: @escaping (UIImage) -> Void) {
        self.onCapture = onCapture
        _scan = State(initialValue: scan)
    }

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
            if scan && ready {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, dash: [12, 7]))
                    .padding(.horizontal, 52).padding(.top, 52).padding(.bottom, 120)
                    .allowsHitTesting(false)
            }
            VStack {
                if scan {
                    Text("Scan receipt").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(.black.opacity(0.35), in: Capsule())
                        .padding(.top, 20).accessibilityIdentifier("camera-scan-mode")
                }
                Spacer()
                ZStack(alignment: .bottom) {
                    HStack(alignment: .bottom) {
                        cameraButton("chevron.left", label: "Close camera") { dismiss() }
                        Spacer()
                        VStack(spacing: 12) {
                            if optionsOpen {
                                cameraButton("doc.viewfinder", label: scan ? "Switch to photo" : "Scan receipt", selected: scan) {
                                    scan.toggle()
                                }
                                cameraButton(flash == .off ? "flash.off" : "flash", label: "Flash: \(flash.rawValue)", selected: flash != .off) {
                                    flash = flash.next
                                }
                                .disabled(!ready || capturing)
                                cameraButton("camera.rotate", label: "Switch camera") { camera.flip() }
                                    .disabled(!ready || capturing)
                            }
                            cameraButton(optionsOpen ? "xmark" : "ellipsis", label: optionsOpen ? "Close camera options" : "Camera options") {
                                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.85)) { optionsOpen.toggle() }
                            }
                        }
                    }
                    Button {
                        AppHaptics.sent()
                        capturing = true
                        camera.capture(scan: scan, flash: flash.mode)
                    } label: {
                        ZStack {
                            Circle().fill(.white.opacity(0.18))
                            Circle().strokeBorder(.white.opacity(0.75), lineWidth: 1)
                            Circle().fill(.white.opacity(0.96)).padding(6)
                            if capturing { ProgressView().tint(.black) }
                        }.frame(width: 68, height: 68)
                            .glassEffect(.regular, in: Circle())
                            .scaleEffect(capturing && !reduceMotion ? 0.92 : 1)
                            .animation(.easeOut(duration: 0.16), value: capturing)
                    }
                    .disabled(!ready || capturing)
                    .accessibilityLabel(scan ? "Scan receipt" : "Take photo")
                    .accessibilityIdentifier("camera-shutter")
                }
                .buttonStyle(.plain).padding(.horizontal, 24).padding(.bottom, 24)
            }.foregroundStyle(.white)
        }
        .background(.black)
        .presentationDetents([.height(480)])
        // Let the system keep the sheet concentric with this device's screen.
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
                else { error = "Couldn't take that photo. Close the camera and try again."; AppHaptics.error() }
            }
        }
        .onDisappear { camera.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.resume() } else { camera.pause() }
        }
    }

    private func cameraButton(_ icon: String, label: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button { AppHaptics.tap(); action() } label: {
            Image(hugeIcon: icon).frame(width: 48, height: 48).contentShape(Circle())
        }
        .accessibilityLabel(label)
        .glassEffect(.regular.tint(selected ? TrolleyStyle.accent.opacity(0.6) : .black.opacity(0.5)), in: Circle())
        .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
    }
}

private enum CameraFlash: String {
    case off, on, auto
    var next: Self { switch self { case .off: .on; case .on: .auto; case .auto: .off } }
    var mode: AVCaptureDevice.FlashMode { switch self { case .off: .off; case .on: .on; case .auto: .auto } }
}

/// Generous attachment rows without UIKit Menu's square pressed highlight.
struct MediaSourceMenu: View {
    let onSelect: (MediaPickerSource) -> Void
    var body: some View {
        VStack(spacing: 2) {
            row("Camera", icon: "camera", source: .camera)
            row("Photos", icon: "photo", source: .photos)
        }.padding(12).frame(width: 260)
    }
    private func row(_ title: String, icon: String, source: MediaPickerSource) -> some View {
        Button { onSelect(source) } label: {
            HStack(spacing: 16) {
                Image(hugeIcon: icon).frame(width: 44, height: 44)
                    .background(TrolleyStyle.surface, in: Circle())
                Text(title).font(.title3)
                Spacer()
            }.padding(.horizontal, 12).frame(minHeight: 68).contentShape(RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain).foregroundStyle(.primary)
    }
}

struct MediaZoomTransition: ViewModifier {
    let namespace: Namespace.ID?
    let sourceID: String
    @ViewBuilder func body(content: Content) -> some View {
        if let namespace { content.navigationTransition(.zoom(sourceID: sourceID, in: namespace)) }
        else { content }
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
    private var scanCapture = false
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

    func capture(scan: Bool, flash: AVCaptureDevice.FlashMode) {
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
            scanCapture = scan
            let settings = AVCapturePhotoSettings()
            if output.supportedFlashModes.contains(flash) { settings.flashMode = flash }
            output.capturePhoto(with: settings, delegate: self)
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
            let result = scanCapture ? image.map(Self.correctPerspective) : image
            Task { @MainActor in callback(result) }
        }
    }
    /// Document mode corrects a confidently detected paper boundary. If the
    /// receipt is cropped or too long to detect, preserve the entire photo.
    private static func correctPerspective(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        // Camera JPEGs can carry portrait orientation as metadata rather than
        // rotated pixels. Keep detection and the corrected output upright.
        let orientation: Int32 = switch image.imageOrientation {
        case .up: 1
        case .upMirrored: 2
        case .down: 3
        case .downMirrored: 4
        case .leftMirrored: 5
        case .right: 6
        case .rightMirrored: 7
        case .left: 8
        @unknown default: 1
        }
        let source = CIImage(cgImage: cgImage).oriented(forExifOrientation: orientation)
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        request.minimumConfidence = 0.8
        request.minimumAspectRatio = 0.1
        request.minimumSize = 0.2
        guard (try? VNImageRequestHandler(ciImage: source).perform([request])) != nil,
              let rectangle = request.results?.first else { return image }
        let extent = source.extent
        func point(_ point: CGPoint) -> CGPoint {
            CGPoint(x: extent.minX + point.x * extent.width, y: extent.minY + point.y * extent.height)
        }
        let correction = CIFilter.perspectiveCorrection()
        correction.inputImage = source
        correction.topLeft = point(rectangle.topLeft)
        correction.topRight = point(rectangle.topRight)
        correction.bottomLeft = point(rectangle.bottomLeft)
        correction.bottomRight = point(rectangle.bottomRight)
        guard let output = correction.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return image }
        return UIImage(cgImage: cgImage)
    }

}
