import SwiftUI
import UIKit

/// The PC screen. Laid out in `freeRect` (the space above the keyboard and
/// the controls, issue #73): fitted and centred there by default, re-fitted
/// when that space changes (keyboard, rotation, controls). Once the user
/// zooms or moves it, it stays where they put it (also at 1x, anywhere on
/// screen) and the placement is remembered per orientation. Double tap (view
/// only) or "Fit picture" goes back to fitted.
/// Gestures become mouse input only while the model is in control mode.
struct DesktopSurface: UIViewRepresentable {
    @ObservedObject var model: DesktopModel
    /// Free space in global (window) coordinates; .zero = the whole view.
    var freeRect: CGRect
    var fitRequest: Int
    var onToggleChrome: () -> Void

    func makeUIView(context: Context) -> DesktopCanvasView {
        let v = DesktopCanvasView()
        v.model = model
        v.onToggleChrome = onToggleChrome
        model.onFrame = { [weak v] image in v?.show(image) }
        model.onCursor = { [weak v] p, on in v?.hostCursor(p, onMonitor: on) }
        return v
    }

    func updateUIView(_ v: DesktopCanvasView, context: Context) {
        v.onToggleChrome = onToggleChrome
        v.apply(control: model.control && model.controlAllowed, trackpad: model.trackpad, panLock: model.panLock)
        v.setKeyboard(model.keyboard && model.control && model.controlAllowed)
        v.setFreeRect(freeRect)
        v.fitRequest(fitRequest)
    }

    static func dismantleUIView(_ v: DesktopCanvasView, coordinator: ()) {
        v.model?.onFrame = nil
        v.model?.onCursor = nil
    }
}

final class DesktopCanvasView: UIView, UIGestureRecognizerDelegate {
    weak var model: DesktopModel?
    var onToggleChrome: (() -> Void)?

    private let imageView = UIImageView()
    private let cursor = UIImageView()
    private let keys = DesktopKeyCapture()

    /// View only: shows/hides the controls. Control: left click.
    private var chromeTap: UITapGestureRecognizer!
    private var tap: UITapGestureRecognizer!
    private var doubleTap: UITapGestureRecognizer!
    private var twoTap: UITapGestureRecognizer!
    /// Moves the picture (view only, or Pan while controlling).
    private var movePan: UIPanGestureRecognizer!
    /// Zooms (always) and follows the fingers (view only / Pan).
    private var pinch: UIPinchGestureRecognizer!
    private var drag: UIPanGestureRecognizer!
    private var twoPan: UIPanGestureRecognizer!
    private var hold: UILongPressGestureRecognizer!

    private var control = false
    private var trackpad = false
    private var panLock = false
    private var imageSize: CGSize = .zero

    /// Picture placement: scale (view points per image pixel) and top-left.
    private var scale: CGFloat = 1
    private var origin: CGPoint = .zero
    /// The user zoomed or moved the picture: keep it, don't re-fit.
    private var userPlaced = false
    private var freeGlobal: CGRect = .zero
    private var lastFree: CGRect = .zero
    private var lastFitRequest = 0

    /// Trackpad pointer, normalized. Follows the PC's real cursor (`cursor`
    /// messages) except while the user moves it.
    private var pointer = CGPoint(x: 0.5, y: 0.5)
    private var lastLocalMove = Date.distantPast
    private var lastPan: CGPoint = .zero
    private var wheelRest: CGFloat = 0
    private var zoomGesture = false
    private var pinchTotal: CGFloat = 1
    private var pinchCentroid: CGPoint = .zero
    private var dragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.03, green: 0.035, blue: 0.04, alpha: 1)
        clipsToBounds = true
        imageView.contentMode = .scaleToFill
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "PC screen"
        imageView.layer.magnificationFilter = .linear
        addSubview(imageView)

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
        movePan = UIPanGestureRecognizer(target: self, action: #selector(onMove(_:)))
        movePan.maximumNumberOfTouches = 1
        pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        drag = UIPanGestureRecognizer(target: self, action: #selector(onDrag(_:)))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        twoPan = UIPanGestureRecognizer(target: self, action: #selector(onTwoPan(_:)))
        twoPan.minimumNumberOfTouches = 2
        twoPan.maximumNumberOfTouches = 2
        hold = UILongPressGestureRecognizer(target: self, action: #selector(onHold(_:)))
        hold.minimumPressDuration = 0.35
        hold.allowableMovement = 12
        for g in [doubleTap!, chromeTap!, tap!, twoTap!, movePan!, pinch!, drag!, twoPan!, hold!] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }
        apply(control: false, trackpad: false, panLock: false, force: true)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Picture

    func show(_ image: UIImage) {
        imageView.image = image
        let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard px != imageSize else { return }
        let old = imageSize
        imageSize = px
        if old == .zero {
            restorePlacement()
        } else if userPlaced, old.width > 0 {
            // New resolution or monitor: keep the shown width and place.
            scale = scale * old.width / px.width
        }
        layoutPicture(animated: false)
    }

    /// The free space in this view's coordinates.
    private var free: CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        var r = freeGlobal == .zero ? bounds : convert(freeGlobal, from: nil)
        r = r.intersection(bounds)
        if r.isNull || r.width < 60 || r.height < 60 { r = bounds }
        // The keyboard while the controls are hidden (they normally report it).
        if keyboardTop < r.maxY {
            r.size.height = max(60, keyboardTop - r.minY)
        }
        return r
    }

    func setFreeRect(_ r: CGRect) {
        guard r != freeGlobal else { return }
        freeGlobal = r
        setNeedsLayout()
    }

    func fitRequest(_ n: Int) {
        guard n != lastFitRequest else { return }
        lastFitRequest = n
        resetToFit(animated: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        keys.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        let rotated = orientationChanged()
        let f = free
        if f != lastFree || rotated {
            lastFree = f
            if rotated { restorePlacement() }
            layoutPicture(animated: !rotated && window != nil)
        }
        updateCursor()
    }

    private var lastLandscape: Bool?

    /// The view itself turned (not just the keyboard shrinking the free space).
    private func orientationChanged() -> Bool {
        guard bounds.width > 0, bounds.height > 0 else { return false }
        let landscape = bounds.width > bounds.height
        defer { lastLandscape = landscape }
        return lastLandscape != nil && lastLandscape != landscape
    }

    private func fitScale() -> CGFloat {
        let f = free
        guard imageSize.width > 0, imageSize.height > 0, f.width > 0, f.height > 0 else { return 1 }
        return min(f.width / imageSize.width, f.height / imageSize.height)
    }

    private var minScale: CGFloat { fitScale() * 0.25 }
    private var maxScale: CGFloat { max(fitScale() * 8, 2.5) }

    /// Fitted and centred in the free space, unless the user placed it.
    private func layoutPicture(animated: Bool) {
        guard imageSize.width > 0, bounds.width > 0 else { return }
        if !userPlaced {
            let f = free
            scale = fitScale()
            let w = imageSize.width * scale, h = imageSize.height * scale
            origin = CGPoint(x: f.midX - w / 2, y: f.midY - h / 2)
        } else {
            scale = min(max(scale, minScale), maxScale)
            clampOrigin()
        }
        let frame = CGRect(origin: origin, size: CGSize(width: imageSize.width * scale, height: imageSize.height * scale))
        if animated && imageView.frame != .zero {
            UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                self.imageView.frame = frame
            } completion: { _ in self.updateCursor() }
        } else {
            imageView.frame = frame
        }
        updateCursor()
    }

    /// Anywhere on screen, but keep part of the picture visible.
    private func clampOrigin() {
        let w = imageSize.width * scale, h = imageSize.height * scale
        let keep: CGFloat = 80
        let kx = min(keep, w), ky = min(keep, h)
        origin.x = min(max(origin.x, bounds.minX + kx - w), bounds.maxX - kx)
        origin.y = min(max(origin.y, bounds.minY + ky - h), bounds.maxY - ky)
    }

    private func setPlacement(scale s: CGFloat, origin o: CGPoint) {
        userPlaced = true
        scale = min(max(s, minScale), maxScale)
        origin = o
        clampOrigin()
        imageView.frame = CGRect(origin: origin, size: CGSize(width: imageSize.width * scale, height: imageSize.height * scale))
        updateCursor()
    }

    /// Zoom by `factor` keeping the image point under `anchor` (view coords) fixed.
    private func zoom(by factor: CGFloat, at anchor: CGPoint) {
        let s = min(max(scale * factor, minScale), maxScale)
        let f = s / scale
        let o = CGPoint(x: anchor.x - (anchor.x - origin.x) * f, y: anchor.y - (anchor.y - origin.y) * f)
        setPlacement(scale: s, origin: o)
    }

    private func resetToFit(animated: Bool) {
        userPlaced = false
        forgetPlacement()
        layoutPicture(animated: animated)
    }

    // MARK: - Remembered placement (per orientation)

    private var placementKey: String {
        "desktop.placement." + (bounds.width > bounds.height ? "landscape" : "portrait")
    }

    /// Saved as zoom relative to fit plus the picture centre relative to the view.
    private func savePlacement() {
        guard userPlaced, imageSize.width > 0, bounds.width > 0, bounds.height > 0 else { return }
        let fit = fitScale()
        let cx = (origin.x + imageSize.width * scale / 2) / bounds.width
        let cy = (origin.y + imageSize.height * scale / 2) / bounds.height
        UserDefaults.standard.set([Double(scale / max(fit, 0.0001)), Double(cx), Double(cy)], forKey: placementKey)
    }

    private func forgetPlacement() {
        UserDefaults.standard.removeObject(forKey: placementKey)
    }

    private func restorePlacement() {
        guard imageSize.width > 0, bounds.width > 0 else { return }
        guard let a = UserDefaults.standard.array(forKey: placementKey) as? [Double], a.count == 3 else {
            userPlaced = false
            return
        }
        userPlaced = true
        scale = fitScale() * CGFloat(a[0])
        let w = imageSize.width * scale, h = imageSize.height * scale
        origin = CGPoint(x: CGFloat(a[1]) * bounds.width - w / 2, y: CGFloat(a[2]) * bounds.height - h / 2)
    }

    // MARK: - Keyboard (while the controls are hidden they don't report it)

    private var keyboardTop: CGFloat = .greatestFiniteMagnitude

    override func didMoveToWindow() {
        super.didMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard window != nil else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrame(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardHide(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardFrame(_ n: Notification) {
        guard let r = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let local = convert(r, from: nil)
        keyboardTop = local.minY < bounds.maxY - 1 && local.height > 0 ? local.minY : .greatestFiniteMagnitude
        setNeedsLayout()
    }

    @objc private func keyboardHide(_ n: Notification) {
        keyboardTop = .greatestFiniteMagnitude
        setNeedsLayout()
    }

    // MARK: - Modes

    func apply(control: Bool, trackpad: Bool, panLock: Bool, force: Bool = false) {
        guard force || control != self.control || trackpad != self.trackpad || panLock != self.panLock else { return }
        if control && trackpad && !(self.control && self.trackpad),
           let p = model?.hostCursor, (0...1).contains(p.x), (0...1).contains(p.y) {
            // The trackpad starts at the PC's real pointer.
            pointer = p
        }
        self.control = control
        self.trackpad = trackpad
        self.panLock = panLock
        let input = control && !panLock
        movePan.isEnabled = !input
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

    /// The PC's pointer moved. The trackpad pointer follows it unless the
    /// user is moving it right now.
    func hostCursor(_ p: CGPoint, onMonitor: Bool) {
        guard onMonitor, Date().timeIntervalSince(lastLocalMove) > 0.4 else { return }
        pointer = CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
        updateCursor()
    }

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
        let f = imageView.frame
        let s = CGPoint(x: f.minX + pointer.x * f.width, y: f.minY + pointer.y * f.height)
        let size = cursor.image?.size ?? CGSize(width: 14, height: 20)
        // The arrow's tip is near the image's top-left corner.
        cursor.frame = CGRect(x: s.x - size.width * 0.3, y: s.y - size.height * 0.15, width: size.width, height: size.height)
    }

    /// Keeps the trackpad pointer inside the free space when zoomed in.
    private func follow() {
        let f = imageView.frame
        let fr = free
        guard f.width > fr.width + 1 || f.height > fr.height + 1 else { return }
        let s = CGPoint(x: f.minX + pointer.x * f.width, y: f.minY + pointer.y * f.height)
        let margin: CGFloat = 40
        var dx: CGFloat = 0, dy: CGFloat = 0
        if s.x < fr.minX + margin { dx = fr.minX + margin - s.x }
        if s.x > fr.maxX - margin { dx = fr.maxX - margin - s.x }
        if s.y < fr.minY + margin { dy = fr.minY + margin - s.y }
        if s.y > fr.maxY - margin { dy = fr.maxY - margin - s.y }
        guard dx != 0 || dy != 0 else { return }
        setPlacement(scale: scale, origin: CGPoint(x: origin.x + dx, y: origin.y + dy))
        savePlacement()
    }

    // MARK: - Gestures

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // The two-finger wheel runs alongside the pinch zoom; so does moving.
        ((g === twoPan || g === movePan) && other === pinch) || (g === pinch && (other === twoPan || other === movePan))
    }

    @objc private func onChromeTap(_ g: UITapGestureRecognizer) {
        onToggleChrome?()
    }

    @objc private func onDoubleTap(_ g: UITapGestureRecognizer) {
        guard imageSize.width > 0 else { return }
        if userPlaced {
            resetToFit(animated: true)
        } else {
            let p = g.location(in: self)
            let target = min(fitScale() * 2.5, maxScale)
            let f = target / scale
            userPlaced = true
            origin = CGPoint(x: p.x - (p.x - origin.x) * f, y: p.y - (p.y - origin.y) * f)
            scale = target
            layoutPicture(animated: true)
            savePlacement()
        }
    }

    /// One finger moves the picture (view only / Pan), with a little momentum.
    @objc private func onMove(_ g: UIPanGestureRecognizer) {
        guard imageSize.width > 0 else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        switch g.state {
        case .changed:
            setPlacement(scale: scale, origin: CGPoint(x: origin.x + t.x, y: origin.y + t.y))
        case .ended:
            let v = g.velocity(in: self)
            let from = imageView.frame.offsetBy(dx: t.x, dy: t.y)
            setPlacement(scale: scale, origin: CGPoint(x: origin.x + t.x + v.x * 0.12, y: origin.y + t.y + v.y * 0.12))
            let to = imageView.frame
            imageView.frame = from
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
                self.imageView.frame = to
            } completion: { _ in self.updateCursor() }
            savePlacement()
        default:
            break
        }
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        guard imageSize.width > 0 else { return }
        let c = g.location(in: self)
        switch g.state {
        case .began:
            pinchTotal = 1
            pinchCentroid = c
            g.scale = 1
        case .changed:
            pinchTotal *= g.scale
            let factor = g.scale
            g.scale = 1
            if inputOn {
                // Controlling: two fingers also scroll; zoom only once it's clearly a pinch.
                guard abs(pinchTotal - 1) > 0.08 else { return }
                zoomGesture = true
                zoom(by: factor, at: c)
            } else {
                // Follow the fingers: move with the centroid, zoom about it.
                if g.numberOfTouches >= 2 {
                    origin.x += c.x - pinchCentroid.x
                    origin.y += c.y - pinchCentroid.y
                }
                pinchCentroid = c
                zoom(by: factor, at: c)
            }
        case .ended, .cancelled:
            if userPlaced { savePlacement() }
        default:
            break
        }
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
            let shown = imageView.frame
            let speed: CGFloat = 1.6
            let dx = t.x / max(shown.width, 1) * speed
            let dy = t.y / max(shown.height, 1) * speed
            pointer.x = min(max(pointer.x + dx, 0), 1)
            pointer.y = min(max(pointer.y + dy, 0), 1)
            lastLocalMove = Date()
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
        lastLocalMove = Date()
        switch g.state {
        case .began:
            Haptics.tap()
            lastPan = here
            model.move(pointer, force: true)
            model.button(0, down: true, at: pointer)
        case .changed:
            let shown = imageView.frame
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
