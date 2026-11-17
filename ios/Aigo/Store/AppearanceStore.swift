import SwiftUI
import UIKit

/// Settings → Appearance: the theme (Slate, Porcelain, Dusk), the code font
/// and the text size. Changing one updates `AigoThemeID.current` /
/// `AigoAppearance.current` (read by `Theme` and `Font.aigo`) and bumps
/// `revision`, which rebuilds the view tree so every screen picks it up.
@MainActor
final class AppearanceStore: ObservableObject {
    @Published private(set) var appearance: AigoAppearance
    @Published private(set) var theme: AigoThemeID
    @Published private(set) var revision = 0

    init() {
        appearance = AigoAppearance.load()
        theme = AigoThemeID.load()
        AigoAppearance.current = appearance
        AigoThemeID.current = theme
        AppearanceStore.applyUIKit(appearance)
    }

    var colorScheme: ColorScheme { theme.colorScheme }

    func setTheme(_ t: AigoThemeID) {
        guard t != theme else { return }
        theme = t
        AigoThemeID.current = t
        UserDefaults.standard.set(t.rawValue, forKey: AigoThemeID.key)
        AppearanceStore.applyUIKit(appearance)
        revision += 1
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
            let w: UIFont.Weight
            switch weight {
            case .bold, .heavy, .black: w = .bold
            case .semibold: w = .semibold
            case .medium: w = .medium
            default: w = .regular
            }
            return .systemFont(ofSize: size * scale, weight: w)
        }
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(AigoPalette.bg)
        nav.shadowColor = UIColor(AigoPalette.line)
        nav.titleTextAttributes = [.font: ui(15, .semibold), .foregroundColor: UIColor(AigoPalette.text)]
        nav.largeTitleTextAttributes = [.font: ui(26, .semibold), .foregroundColor: UIColor(AigoPalette.text)]
        let button = UIBarButtonItemAppearance()
        button.normal.titleTextAttributes = [.font: ui(14, .regular)]
        nav.buttonAppearance = button
        nav.doneButtonAppearance = button
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UISegmentedControl.appearance().setTitleTextAttributes([.font: ui(13, .regular)], for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes([.font: ui(13, .medium)], for: .selected)
        UISegmentedControl.appearance().selectedSegmentTintColor = UIColor(AigoPalette.raised)
        // Forms and lists keep the theme's background between rows.
        UITableView.appearance().backgroundColor = UIColor(AigoPalette.bg)
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
