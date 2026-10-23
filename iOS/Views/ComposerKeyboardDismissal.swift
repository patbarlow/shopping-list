import SwiftUI
import UIKit

/// Observe drags that begin inside the composer, including inside UIKit's
/// text fields. A SwiftUI DragGesture alone loses those touches to selection.
struct ComposerKeyboardDismissal: UIViewRepresentable {
    let enabled: Bool
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> ComposerSwipeView { ComposerSwipeView() }
    func updateUIView(_ view: ComposerSwipeView, context: Context) {
        view.onDismiss = onDismiss
        view.pan.isEnabled = enabled
    }
    static func dismantleUIView(_ view: ComposerSwipeView, coordinator: ()) { view.detach() }
}

final class ComposerSwipeView: UIView, UIGestureRecognizerDelegate {
    var onDismiss: (() -> Void)?
    private weak var gestureWindow: UIWindow?
    private var dismissed = false
    lazy var pan: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        gesture.delegate = self
        gesture.cancelsTouchesInView = false
        gesture.maximumNumberOfTouches = 1
        return gesture
    }()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        detach()
        guard let window else { return }
        gestureWindow = window
        window.addGestureRecognizer(pan)
    }

    func detach() {
        gestureWindow?.removeGestureRecognizer(pan)
        gestureWindow = nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let window, !isHidden, bounds.width > 0,
              convert(bounds, to: window).contains(touch.location(in: window)) else { return false }
        // Only the composer's own presentation may respond, not a sheet above it.
        var ancestor = superview
        while let view = ancestor {
            if view.next is UIViewController {
                return touch.view?.isDescendant(of: view) == true
            }
            ancestor = view.superview
        }
        return false
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let velocity = pan.velocity(in: window)
        return velocity.y > abs(velocity.x)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { dismissed = false }
        let movement = gesture.translation(in: window)
        guard !dismissed, movement.y > 20, movement.y > abs(movement.x) else { return }
        dismissed = true
        onDismiss?()
        window?.endEditing(true)
    }
}
