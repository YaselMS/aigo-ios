import SwiftUI
import UIKit

/// The PC screen: fitted to the view, pinch to zoom, pan when zoomed.
/// Gestures become mouse input only while the model is in control mode.
struct DesktopSurface: UIViewRepresentable {
    @ObservedObject var model: DesktopModel
    var onToggleChrome: () -> Void

    func makeUIView(context: Context) -> DesktopCanvasView {
        let v = DesktopCanvasView()
        v.model = model
        v.onToggleChrome = onToggleChrome
        model.onFrame = { [weak v] image in v?.show(image) }
        return v
    }

    func updateUIView(_ v: DesktopCanvasView, context: Context) {
        v.onToggleChrome = onToggleChrome
        v.apply(control: model.control, trackpad: model.trackpad, panLock: model.panLock)
        v.setKeyboard(model.keyboard && model.control)
    }

    static func dismantleUIView(_ v: DesktopCanvasView, coordinator: ()) {
        v.model?.onFrame = nil
    }
}

final class DesktopCanvasView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    weak var model: DesktopModel?
    var onToggleChrome: (() -> Void)?

    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private let cursor = UIImageView()
    private let keys = DesktopKeyCapture()

    /// View only: shows/hides the controls. Control: left click.
    private var chromeTap: UITapGestureRecognizer!
    private var tap: UITapGestureRecognizer!
    private var doubleTap: UITapGestureRecognizer!
    private var twoTap: UITapGestureRecognizer!
    private var drag: UIPanGestureRecognizer!
    private var twoPan: UIPanGestureRecognizer!
    private var hold: UILongPressGestureRecognizer!

    private var control = false
    private var trackpad = false
    private var panLock = false
    private var imageSize: CGSize = .zero
    /// Trackpad pointer, normalized. The PC doesn't report its real cursor,
    /// so the first move puts it here.
    private var pointer = CGPoint(x: 0.5, y: 0.5)
    private var lastPan: CGPoint = .zero
    private var wheelRest: CGFloat = 0
    private var zoomGesture = false
    private var dragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.03, green: 0.035, blue: 0.04, alpha: 1)
        scroll.delegate = self
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.bouncesZoom = true
        scroll.decelerationRate = .fast
        scroll.delaysContentTouches = false
        addSubview(scroll)
        imageView.contentMode = .scaleToFill
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "PC screen"
        imageView.layer.magnificationFilter = .linear
        scroll.addSubview(imageView)

        let conf = UIImage.SymbolConfiguration(pointSize: 18, weight: .bold)
        cursor.image = UIImage(systemName: "cursorarrow", withConfiguration: conf)?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        cursor.layer.shadowColor = UIColor.black.cgColor
        cursor.layer.shadowOpacity = 0.9
        cursor.layer.shadowRadius = 1.5
        cursor.layer.shadowOffset = .zero
        cursor.isHidden = true
        cursor.isUserInteractionEnabled = false
        addSubview(cursor)

        keys.onText = { [weak self] t in self?.model?.typeText(t) }
        keys.onBackspace = { [weak self] in self?.model?.press(code: "Backspace", key: "Backspace") }
        keys.onKey = { [weak self] code, key in self?.model?.press(code: code, key: key) }
        addSubview(keys)

        doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        chromeTap = UITapGestureRecognizer(target: self, action: #selector(onChromeTap(_:)))
        chromeTap.require(toFail: doubleTap)
        tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        twoTap = UITapGestureRecognizer(target: self, action: #selector(onTwoTap(_:)))
        twoTap.numberOfTouchesRequired = 2
        drag = UIPanGestureRecognizer(target: self, action: #selector(onDrag(_:)))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        twoPan = UIPanGestureRecognizer(target: self, action: #selector(onTwoPan(_:)))
        twoPan.minimumNumberOfTouches = 2
        twoPan.maximumNumberOfTouches = 2
        hold = UILongPressGestureRecognizer(target: self, action: #selector(onHold(_:)))
        hold.minimumPressDuration = 0.35
        hold.allowableMovement = 12
        for g in [doubleTap!, chromeTap!, tap!, twoTap!, drag!, twoPan!, hold!] as [UIGestureRecognizer] {
            g.delegate = self
            scroll.addGestureRecognizer(g)
        }
        apply(control: false, trackpad: false, panLock: false, force: true)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Picture

    func show(_ image: UIImage) {
        imageView.image = image
        let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        if px != imageSize {
            imageSize = px
            configureZoom(reset: true)
        }
    }

    private var lastBounds: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        keys.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        if bounds.size != lastBounds {
            lastBounds = bounds.size
            configureZoom(reset: false)
        }
        updateCursor()
    }

    private func fitScale() -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(bounds.width / imageSize.width, bounds.height / imageSize.height)
    }

    /// Fit-to-screen is the minimum zoom; the picture stays fitted when the
    /// phone rotates unless the user had zoomed in.
    private func configureZoom(reset: Bool) {
        guard imageSize.width > 0 else { return }
        let prev = scroll.zoomScale
        let wasFitted = prev <= scroll.minimumZoomScale + 0.001
        let fit = fitScale()
        if reset {
            scroll.zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: imageSize)
            scroll.contentSize = imageSize
        }
        scroll.minimumZoomScale = fit
        scroll.maximumZoomScale = max(fit * 8, 2.5)
        scroll.zoomScale = (reset || wasFitted) ? fit : max(prev, fit)
        center()
    }

    private func center() {
        let w = imageView.frame.width, h = imageView.frame.height
        let x = max((scroll.bounds.width - w) / 2, 0)
        let y = max((scroll.bounds.height - h) / 2, 0)
        scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        center()
        updateCursor()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateCursor()
    }

    @objc private func onDoubleTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: imageView)
        if scroll.zoomScale > scroll.minimumZoomScale + 0.01 {
            scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
        } else {
            let target = min(scroll.minimumZoomScale * 2.5, scroll.maximumZoomScale)
            let w = scroll.bounds.width / target, h = scroll.bounds.height / target
            scroll.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
        }
    }

    // MARK: - Modes

    func apply(control: Bool, trackpad: Bool, panLock: Bool, force: Bool = false) {
        guard force || control != self.control || trackpad != self.trackpad || panLock != self.panLock else { return }
        self.control = control
        self.trackpad = trackpad
        self.panLock = panLock
        let input = control && !panLock
        scroll.panGestureRecognizer.isEnabled = !input
        doubleTap.isEnabled = !input
        chromeTap.isEnabled = !input
        tap.isEnabled = input
        twoTap.isEnabled = input
        drag.isEnabled = input
        twoPan.isEnabled = input
        hold.isEnabled = input && trackpad
        updateCursor()
    }

    func setKeyboard(_ on: Bool) {
        if on && !keys.isFirstResponder {
            keys.becomeFirstResponder()
        } else if !on && keys.isFirstResponder {
            keys.resignFirstResponder()
        }
    }

    private var inputOn: Bool { control && !panLock }

    // MARK: - Coordinates

    private func normalized(_ g: UIGestureRecognizer) -> CGPoint {
        let p = g.location(in: imageView)
        let w = max(imageView.bounds.width, 1), h = max(imageView.bounds.height, 1)
        return CGPoint(x: min(max(p.x / w, 0), 1), y: min(max(p.y / h, 0), 1))
    }

    private func pointerTarget(_ g: UIGestureRecognizer) -> CGPoint {
        trackpad ? pointer : normalized(g)
    }

    private func updateCursor() {
        cursor.isHidden = !(control && trackpad) || imageSize.width == 0
        guard !cursor.isHidden else { return }
        let p = CGPoint(x: pointer.x * imageView.bounds.width, y: pointer.y * imageView.bounds.height)
        let s = imageView.convert(p, to: self)
        let size = cursor.image?.size ?? CGSize(width: 14, height: 20)
        // The arrow's tip is near the image's top-left corner.
        cursor.frame = CGRect(x: s.x - size.width * 0.3, y: s.y - size.height * 0.15, width: size.width, height: size.height)
    }

    /// Keeps the trackpad pointer in view when zoomed in.
    private func follow() {
        guard scroll.zoomScale > scroll.minimumZoomScale + 0.01 else { return }
        let p = CGPoint(x: pointer.x * imageView.bounds.width, y: pointer.y * imageView.bounds.height)
        let s = imageView.convert(p, to: scroll)
        let margin: CGFloat = 40
        scroll.scrollRectToVisible(CGRect(x: s.x - margin, y: s.y - margin, width: margin * 2, height: margin * 2), animated: false)
    }

    // MARK: - Gestures

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // The two-finger wheel runs alongside the scroll view's pinch zoom.
        (g === twoPan && other === scroll.pinchGestureRecognizer) || (other === twoPan && g === scroll.pinchGestureRecognizer)
    }

    @objc private func onChromeTap(_ g: UITapGestureRecognizer) {
        onToggleChrome?()
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        guard inputOn, let model = model else { return }
        Haptics.selection()
        model.click(0, at: pointerTarget(g))
    }

    @objc private func onTwoTap(_ g: UITapGestureRecognizer) {
        guard inputOn, let model = model else { return }
        Haptics.tap()
        model.click(2, at: pointerTarget(g))
    }

    @objc private func onDrag(_ g: UIPanGestureRecognizer) {
        guard inputOn, let model = model else { return }
        if trackpad {
            // Relative movement, scaled to the picture as shown (finer when
            // zoomed in): a swipe across the picture moves 1.6 screens.
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            let shown = imageView.convert(imageView.bounds, to: self)
            let speed: CGFloat = 1.6
            let dx = t.x / max(shown.width, 1) * speed
            let dy = t.y / max(shown.height, 1) * speed
            pointer.x = min(max(pointer.x + dx, 0), 1)
            pointer.y = min(max(pointer.y + dy, 0), 1)
            model.move(pointer, force: g.state == .ended)
            updateCursor()
            follow()
            return
        }
        let p = normalized(g)
        switch g.state {
        case .began:
            dragging = true
            model.move(p, force: true)
            model.button(0, down: true, at: p)
        case .changed:
            model.move(p)
        case .ended, .cancelled, .failed:
            if dragging {
                dragging = false
                model.move(p, force: true)
                model.button(0, down: false, at: p)
            }
        default:
            break
        }
    }

    /// Trackpad: press and hold, then move = drag with the left button.
    @objc private func onHold(_ g: UILongPressGestureRecognizer) {
        guard inputOn, trackpad, let model = model else { return }
        let here = g.location(in: self)
        switch g.state {
        case .began:
            Haptics.tap()
            lastPan = here
            model.move(pointer, force: true)
            model.button(0, down: true, at: pointer)
        case .changed:
            let shown = imageView.convert(imageView.bounds, to: self)
            pointer.x = min(max(pointer.x + (here.x - lastPan.x) / max(shown.width, 1) * 1.6, 0), 1)
            pointer.y = min(max(pointer.y + (here.y - lastPan.y) / max(shown.height, 1) * 1.6, 0), 1)
            lastPan = here
            model.move(pointer)
            updateCursor()
            follow()
        default:
            model.move(pointer, force: true)
            model.button(0, down: false, at: pointer)
        }
    }

    /// Two fingers moving together = mouse wheel. A pinch zooms instead.
    @objc private func onTwoPan(_ g: UIPanGestureRecognizer) {
        guard inputOn, let model = model else { return }
        switch g.state {
        case .began:
            wheelRest = 0
            zoomGesture = false
        case .changed:
            if let pinch = scroll.pinchGestureRecognizer, abs(pinch.scale - 1) > 0.08 {
                zoomGesture = true
            }
            if zoomGesture { return }
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            // Natural scrolling: fingers down = content down = wheel up.
            wheelRest += t.y * 4
            let notch = Int(wheelRest)
            if abs(notch) >= 30 {
                wheelRest -= CGFloat(notch)
                model.wheel(notch, at: pointerTarget(g))
            }
        default:
            break
        }
    }
}

/// Invisible first responder that turns the iOS keyboard into key events.
final class DesktopKeyCapture: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onKey: ((String, String) -> Void)?

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    func insertText(_ text: String) {
        onText?(text)
    }

    func deleteBackward() {
        onBackspace?()
    }

    /// Hardware keyboard: arrows and Escape don't arrive as text.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses {
            guard let k = p.key else { continue }
            let map: [UIKeyboardHIDUsage: (String, String)] = [
                .keyboardEscape: ("Escape", "Escape"),
                .keyboardLeftArrow: ("ArrowLeft", "ArrowLeft"),
                .keyboardRightArrow: ("ArrowRight", "ArrowRight"),
                .keyboardUpArrow: ("ArrowUp", "ArrowUp"),
                .keyboardDownArrow: ("ArrowDown", "ArrowDown"),
            ]
            if let pair = map[k.keyCode] {
                onKey?(pair.0, pair.1)
                handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }
}
