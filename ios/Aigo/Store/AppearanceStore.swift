import SwiftUI
import UIKit

/// Settings → Appearance: the UI font and the text size. Changing either
/// updates `AigoAppearance.current` (read by `Font.aigo`) and bumps
/// `revision`, which rebuilds the view tree so every screen picks it up.
@MainActor
final class AppearanceStore: ObservableObject {
    @Published private(set) var appearance: AigoAppearance
    @Published private(set) var revision = 0

    init() {
        appearance = AigoAppearance.load()
        AigoAppearance.current = appearance
        AppearanceStore.applyUIKit(appearance)
    }

    var family: AigoFontFamily {
        get { appearance.family }
        set { set(AigoAppearance(family: newValue, size: appearance.size)) }
    }

    var size: AigoTextSize {
        get { appearance.size }
        set { set(AigoAppearance(family: appearance.family, size: newValue)) }
    }

    private func set(_ a: AigoAppearance) {
        guard a != appearance else { return }
        appearance = a
        AigoAppearance.current = a
        UserDefaults.standard.set(a.family.rawValue, forKey: AigoAppearance.familyKey)
        UserDefaults.standard.set(a.size.rawValue, forKey: AigoAppearance.sizeKey)
        AppearanceStore.applyUIKit(a)
        revision += 1
    }

    /// Navigation bar titles, bar buttons and segmented controls (UIKit).
    static func applyUIKit(_ a: AigoAppearance) {
        let scale = a.size.scale
        func ui(_ size: CGFloat, _ weight: Font.Weight) -> UIFont {
            UIFont(name: a.family.postScriptName(weight), size: size * scale)
                ?? .monospacedSystemFont(ofSize: size * scale, weight: weight == .regular ? .regular : .semibold)
        }
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(AigoPalette.background)
        nav.shadowColor = UIColor(AigoPalette.line)
        nav.titleTextAttributes = [.font: ui(15, .semibold), .foregroundColor: UIColor(AigoPalette.text)]
        nav.largeTitleTextAttributes = [.font: ui(26, .bold), .foregroundColor: UIColor(AigoPalette.text)]
        let button = UIBarButtonItemAppearance()
        button.normal.titleTextAttributes = [.font: ui(14, .regular)]
        nav.buttonAppearance = button
        nav.doneButtonAppearance = button
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UISegmentedControl.appearance().setTitleTextAttributes([.font: ui(13, .regular)], for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes([.font: ui(13, .semibold)], for: .selected)
    }
}

/// Lets the system back-swipe work on screens that hide the navigation bar
/// (Home, Conversation draw their own headers).
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
