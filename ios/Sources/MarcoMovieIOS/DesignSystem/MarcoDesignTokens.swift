// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Apple Design System Tokens, Typography, Symbols, Theme & Adaptive CTAs

import UIKit

// MARK: - Color Tokens

public enum MarcoColors {
    /// Dynamic light/dark helper with crisp Apple surface calibration.
    public static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? dark : light
        }
    }

    /// Primary canvas background: Apple grouped light (#F2F2F7) and deep cinema obsidian (#0B0C10).
    public static let canvasBackground: UIColor = dynamic(
        light: UIColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1.0),
        dark: UIColor(red: 0.043, green: 0.047, blue: 0.063, alpha: 1.0)
    )

    /// Elevated card surface: crisp white (#FFFFFF) in Light Mode, obsidian slate (#161820) in Dark Mode.
    public static let cardSurface: UIColor = dynamic(
        light: UIColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1.0),
        dark: UIColor(red: 0.086, green: 0.094, blue: 0.125, alpha: 1.0)
    )

    /// Secondary elevated surface for nested pills, popovers, and grouped controls.
    public static let elevatedSurface: UIColor = dynamic(
        light: UIColor(red: 0.980, green: 0.982, blue: 0.992, alpha: 1.0),
        dark: UIColor(red: 0.118, green: 0.129, blue: 0.169, alpha: 1.0)
    )

    /// Subtle filled pill/input surface without harsh borders.
    public static let subtleFill: UIColor = dynamic(
        light: UIColor(red: 0.463, green: 0.463, blue: 0.502, alpha: 0.10),
        dark: UIColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 0.08)
    )

    /// Primary editorial ink.
    public static let primaryText: UIColor = dynamic(
        light: UIColor(red: 0.071, green: 0.075, blue: 0.094, alpha: 1.0),
        dark: UIColor(red: 0.961, green: 0.965, blue: 0.980, alpha: 1.0)
    )

    /// Secondary metadata ink.
    public static let secondaryText: UIColor = dynamic(
        light: UIColor(red: 0.110, green: 0.114, blue: 0.137, alpha: 0.62),
        dark: UIColor(red: 0.922, green: 0.933, blue: 0.973, alpha: 0.64)
    )

    /// Tertiary caption/footnote ink.
    public static let tertiaryText: UIColor = dynamic(
        light: UIColor(red: 0.110, green: 0.114, blue: 0.137, alpha: 0.40),
        dark: UIColor(red: 0.922, green: 0.933, blue: 0.973, alpha: 0.40)
    )

    /// Hairline separator token.
    public static let separator: UIColor = dynamic(
        light: UIColor(red: 0.235, green: 0.235, blue: 0.263, alpha: 0.14),
        dark: UIColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 0.12)
    )

    /// Ultra-subtle hairline edge for posters and cards (single hairline, never double borders).
    public static let hairlineBorder: UIColor = dynamic(
        light: UIColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 0.07),
        dark: UIColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 0.11)
    )

    /// Refined Apple cinema tint (understated, never neon).
    public static let accentTint: UIColor = dynamic(
        light: UIColor(red: 0.000, green: 0.443, blue: 0.890, alpha: 1.0),
        dark: UIColor(red: 0.369, green: 0.659, blue: 1.000, alpha: 1.0)
    )

    /// Warm cinema gold used sparingly for ratings/editorial highlights.
    public static let ratingGold: UIColor = dynamic(
        light: UIColor(red: 0.788, green: 0.525, blue: 0.043, alpha: 1.0),
        dark: UIColor(red: 0.976, green: 0.769, blue: 0.278, alpha: 1.0)
    )

    /// Cinema hero scrim protecting foreground typography over full-bleed artwork.
    public static let cinemaHeroScrim: UIColor = dynamic(
        light: UIColor(red: 0.043, green: 0.047, blue: 0.063, alpha: 0.72),
        dark: UIColor(red: 0.043, green: 0.047, blue: 0.063, alpha: 0.84)
    )

    /// Primary solid CTA fill: deep obsidian in Light Mode, pure Apple TV+ white in Dark Mode.
    public static let primaryActionFill: UIColor = dynamic(
        light: UIColor(red: 0.078, green: 0.082, blue: 0.106, alpha: 1.0),
        dark: UIColor(red: 0.988, green: 0.988, blue: 0.996, alpha: 1.0)
    )

    /// Primary solid CTA foreground contrasting with `primaryActionFill`.
    public static let primaryActionForeground: UIColor = dynamic(
        light: UIColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1.0),
        dark: UIColor(red: 0.043, green: 0.047, blue: 0.063, alpha: 1.0)
    )

    /// Destructive action color.
    public static let destructive: UIColor = dynamic(
        light: UIColor(red: 0.851, green: 0.176, blue: 0.125, alpha: 1.0),
        dark: UIColor(red: 1.000, green: 0.271, blue: 0.227, alpha: 1.0)
    )

    /// Semantic success tint.
    public static let success: UIColor = dynamic(
        light: UIColor(red: 0.141, green: 0.541, blue: 0.239, alpha: 1.0),
        dark: UIColor(red: 0.188, green: 0.820, blue: 0.345, alpha: 1.0)
    )

    /// Base placeholder fill beneath poster artwork before decode completes.
    public static let posterPlaceholderBase: UIColor = dynamic(
        light: UIColor(red: 0.898, green: 0.902, blue: 0.925, alpha: 1.0),
        dark: UIColor(red: 0.102, green: 0.114, blue: 0.149, alpha: 1.0)
    )
}

// MARK: - Spacing & Radii

public enum MarcoSpacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 20
    public static let xl: CGFloat = 28
    public static let xxl: CGFloat = 36

    public static func horizontalMargin(for traitCollection: UITraitCollection) -> CGFloat {
        traitCollection.horizontalSizeClass == .regular ? 28 : 16
    }
}

public enum MarcoRadii {
    public static let poster: CGFloat = 12
    public static let card: CGFloat = 16
    public static let hero: CGFloat = 20
    public static let sheet: CGFloat = 24
    public static let pill: CGFloat = 999
}

public extension UIView {
    /// Applies Apple continuous superellipse corner geometry.
    func applyContinuousCorners(_ radius: CGFloat, clipsToBounds: Bool = true) {
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        self.clipsToBounds = clipsToBounds
    }

    /// Applies capsule corner radius based on current bounds.
    func applyPillCorners() {
        let radius = min(bounds.width, bounds.height) * 0.5
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        clipsToBounds = true
    }

    /// Subtle single-pixel hairline border aligned to display scale.
    func applyHairlineBorder(color: UIColor = MarcoColors.hairlineBorder, width: CGFloat? = nil) {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        layer.borderWidth = width ?? (1.0 / max(scale, 1.0))
        layer.borderColor = color.cgColor
    }
}

// MARK: - Typography (San Francisco + PingFang SC Cascade)

public enum MarcoTypography {
    private static func scaledFont(
        size: CGFloat,
        weight: UIFont.Weight,
        textStyle: UIFont.TextStyle,
        design: UIFontDescriptor.SystemDesign = .default,
        maximumPointSize: CGFloat? = nil
    ) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let styled: UIFont
        if design != .default, let descriptor = base.fontDescriptor.withDesign(design) {
            styled = UIFont(descriptor: descriptor, size: size)
        } else {
            styled = base
        }
        let metrics = UIFontMetrics(forTextStyle: textStyle)
        if let maxSize = maximumPointSize {
            return metrics.scaledFont(for: styled, maximumPointSize: maxSize)
        }
        return metrics.scaledFont(for: styled)
    }

    /// Hero display title for cinema banners and detail backdrops.
    public static var heroTitle: UIFont {
        scaledFont(size: 30, weight: .bold, textStyle: .largeTitle, maximumPointSize: 40)
    }

    /// Large navigation / page title.
    public static var largeTitle: UIFont {
        scaledFont(size: 32, weight: .bold, textStyle: .largeTitle, maximumPointSize: 42)
    }

    /// Apple TV+ shelf section header.
    public static var sectionHeader: UIFont {
        scaledFont(size: 20, weight: .bold, textStyle: .title2, maximumPointSize: 28)
    }

    /// Poster and media card title (2-line crisp legibility).
    public static var cardTitle: UIFont {
        scaledFont(size: 14.5, weight: .semibold, textStyle: .subheadline, maximumPointSize: 19)
    }

    /// Poster and media card subtitle / metadata.
    public static var cardSubtitle: UIFont {
        scaledFont(size: 12.5, weight: .regular, textStyle: .footnote, maximumPointSize: 16)
    }

    /// Standard reading body copy.
    public static var body: UIFont {
        scaledFont(size: 15.5, weight: .regular, textStyle: .body, maximumPointSize: 22)
    }

    /// Emphasized reading body copy / primary button labels.
    public static var bodySemibold: UIFont {
        scaledFont(size: 15.5, weight: .semibold, textStyle: .body, maximumPointSize: 21)
    }

    /// Compact caption / pill label.
    public static var caption: UIFont {
        scaledFont(size: 11.5, weight: .medium, textStyle: .caption1, maximumPointSize: 15)
    }

    /// Badge pill text.
    public static var badge: UIFont {
        scaledFont(size: 11.0, weight: .semibold, textStyle: .caption2, maximumPointSize: 14)
    }

    /// Tabular numerals for timecodes, ratings, episode numbers, and PIN counters.
    public static func monospacedDigits(
        size: CGFloat = 14,
        weight: UIFont.Weight = .medium,
        textStyle: UIFont.TextStyle = .footnote
    ) -> UIFont {
        let base = UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: base, maximumPointSize: size * 1.4)
    }
}

// MARK: - SF Symbols Helper

public enum MarcoSymbols {
    /// Creates an SF Symbol image with iOS 15+ hierarchical/palette rendering and clean iOS 14 fallback.
    public static func image(
        _ name: String,
        pointSize: CGFloat,
        weight: UIImage.SymbolWeight = .medium,
        scale: UIImage.SymbolScale = .default,
        hierarchicalColor: UIColor? = nil,
        paletteColors: [UIColor]? = nil
    ) -> UIImage? {
        var config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight, scale: scale)
        if #available(iOS 15.0, *) {
            if let palette = paletteColors, !palette.isEmpty {
                config = config.applying(UIImage.SymbolConfiguration(paletteColors: palette))
                return UIImage(systemName: name, withConfiguration: config)
            }
            if let hierarchical = hierarchicalColor {
                config = config.applying(UIImage.SymbolConfiguration(hierarchicalColor: hierarchical))
                return UIImage(systemName: name, withConfiguration: config)
            }
            return UIImage(systemName: name, withConfiguration: config)
        } else {
            guard let symbol = UIImage(systemName: name, withConfiguration: config) else {
                return nil
            }
            if let fallbackTint = paletteColors?.first ?? hierarchicalColor {
                return symbol.withTintColor(fallbackTint, renderingMode: .alwaysOriginal)
            }
            return symbol
        }
    }

    /// Triggers native iOS 17+ SF Symbol bounce animation with subtle tactile spring fallback on iOS 14–16.
    public static func bounce(_ imageView: UIImageView) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        if #available(iOS 17.0, *) {
            imageView.addSymbolEffect(.bounce, options: .nonRepeating, animated: true)
        } else {
            UIView.animate(
                withDuration: 0.14,
                delay: 0,
                options: [.curveEaseOut, .allowUserInteraction],
                animations: {
                    imageView.transform = CGAffineTransform(scaleX: 1.18, y: 1.18)
                },
                completion: { _ in
                    UIView.animate(
                        withDuration: 0.24,
                        delay: 0,
                        usingSpringWithDamping: 0.62,
                        initialSpringVelocity: 0.4,
                        options: [.allowUserInteraction],
                        animations: {
                            imageView.transform = .identity
                        }
                    )
                }
            )
        }
    }
}

// MARK: - Haptics

public enum MarcoHaptics {
    public static func light() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    public static func medium() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    public static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
    }

    public static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    public static func warning() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
    }

    public static func error() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
    }
}

// MARK: - Theme Manager

public enum MarcoThemeMode: Int, CaseIterable, Sendable {
    case system = 0
    case light = 1
    case dark = 2

    public var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    public var displayTitle: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色外观"
        case .dark: return "深色影院"
        }
    }
}

public final class MarcoThemeManager {
    public static let shared = MarcoThemeManager()
    public static let didChangeThemeNotification = Notification.Name("MarcoThemeManagerDidChangeTheme")

    private let defaultsKey = "marco_ios_theme_mode"

    public private(set) var mode: MarcoThemeMode

    private init() {
        let stored = UserDefaults.standard.integer(forKey: defaultsKey)
        self.mode = MarcoThemeMode(rawValue: stored) ?? .system
    }

    public var currentInterfaceStyle: UIUserInterfaceStyle {
        mode.userInterfaceStyle
    }

    /// Applies the selected theme mode across every connected `UIWindowScene`.
    public func apply(_ newMode: MarcoThemeMode, animated: Bool = true) {
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: defaultsKey)

        let style = newMode.userInterfaceStyle
        let updateWindows = {
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows {
                    if animated && !UIAccessibility.isReduceMotionEnabled {
                        UIView.transition(
                            with: window,
                            duration: 0.22,
                            options: [.transitionCrossDissolve, .allowAnimatedContent],
                            animations: {
                                window.overrideUserInterfaceStyle = style
                            }
                        )
                    } else {
                        window.overrideUserInterfaceStyle = style
                    }
                }
            }
            NotificationCenter.default.post(name: Self.didChangeThemeNotification, object: self)
        }

        if Thread.isMainThread {
            updateWindows()
        } else {
            DispatchQueue.main.async(execute: updateWindows)
        }
    }

    /// Applies the current theme mode to a newly created window.
    public func apply(to window: UIWindow) {
        window.overrideUserInterfaceStyle = mode.userInterfaceStyle
    }

    /// Resolves whether dark styling is currently active for a given trait collection.
    public func isEffectiveDark(in traitCollection: UITraitCollection? = nil) -> Bool {
        switch mode {
        case .dark:
            return true
        case .light:
            return false
        case .system:
            if let traits = traitCollection {
                return traits.userInterfaceStyle == .dark
            }
            return UIScreen.main.traitCollection.userInterfaceStyle == .dark
        }
    }
}

// MARK: - Adaptive Primary & Secondary Glass CTA Buttons

/// Apple TV+ / Infuse primary action button:
/// Pure solid white (on dark / hero backdrops) or obsidian (on light canvas), with optional iOS 26 `.prominentGlass()`,
/// iOS 15+ `UIButton.Configuration`, clean iOS 14 fallback, spring press physics, and iPad `UIPointerInteraction`.
public final class MarcoPrimaryButton: UIButton, UIPointerInteractionDelegate {
    public enum Appearance {
        /// Adapts cleanly to canvas polarity (obsidian in Light Mode, pure white in Dark Mode).
        case adaptiveSolid
        /// Pure solid white pill for dark cinema hero overlays (Apple TV+ signature CTA).
        case heroWhite
        /// Uses native iOS 26 `.prominentGlass()` when available, falling back to `adaptiveSolid`.
        case prominentGlass
    }

    private var appearanceStyle: Appearance
    private var currentTitleText: String
    private var currentSymbolName: String?
    private var pillCornerMode: Bool

    public init(
        title: String,
        symbolName: String? = nil,
        appearance: Appearance = .adaptiveSolid,
        isPill: Bool = true
    ) {
        self.appearanceStyle = appearance
        self.currentTitleText = title
        self.currentSymbolName = symbolName
        self.pillCornerMode = isPill
        super.init(frame: .zero)
        commonSetup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func commonSetup() {
        translatesAutoresizingMaskIntoConstraints = false
        adjustsImageWhenHighlighted = false
        layer.cornerCurve = .continuous
        addInteraction(UIPointerInteraction(delegate: self))
        rebuildAppearance()
    }

    public func setContent(title: String, symbolName: String? = nil) {
        currentTitleText = title
        currentSymbolName = symbolName
        rebuildAppearance()
    }

    public func setAppearance(_ appearance: Appearance) {
        appearanceStyle = appearance
        rebuildAppearance()
    }

    public override var intrinsicContentSize: CGSize {
        let base = super.intrinsicContentSize
        return CGSize(width: max(base.width, 88), height: max(base.height, 46))
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        if pillCornerMode {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *), appearanceStyle == .prominentGlass {
                return
            }
            #endif
            layer.cornerRadius = bounds.height * 0.5
            layer.cornerCurve = .continuous
        } else {
            layer.cornerRadius = MarcoRadii.poster
            layer.cornerCurve = .continuous
        }
    }

    public override var isHighlighted: Bool {
        didSet {
            guard !UIAccessibility.isReduceMotionEnabled else {
                alpha = isHighlighted ? 0.82 : 1.0
                return
            }
            UIView.animate(
                withDuration: isHighlighted ? 0.12 : 0.24,
                delay: 0,
                usingSpringWithDamping: 0.78,
                initialSpringVelocity: 0.3,
                options: [.allowUserInteraction, .beginFromCurrentState],
                animations: {
                    self.transform = self.isHighlighted
                        ? CGAffineTransform(scaleX: 0.965, y: 0.965)
                        : .identity
                    self.alpha = self.isHighlighted ? 0.88 : 1.0
                }
            )
        }
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            rebuildAppearance()
        }
    }

    private func resolvedColors() -> (fill: UIColor, foreground: UIColor) {
        switch appearanceStyle {
        case .heroWhite:
            return (
                UIColor.white,
                UIColor(red: 0.043, green: 0.047, blue: 0.063, alpha: 1.0)
            )
        case .adaptiveSolid, .prominentGlass:
            return (MarcoColors.primaryActionFill, MarcoColors.primaryActionForeground)
        }
    }

    private func rebuildAppearance() {
        let colors = resolvedColors()
        let symbol = currentSymbolName.flatMap {
            MarcoSymbols.image($0, pointSize: 15, weight: .semibold)
        }

        if #available(iOS 15.0, *) {
            var attrTitle = AttributedString(currentTitleText)
            attrTitle.font = MarcoTypography.bodySemibold

            #if compiler(>=6.2)
            if #available(iOS 26.0, *), appearanceStyle == .prominentGlass {
                var cfg = UIButton.Configuration.prominentGlass()
                cfg.attributedTitle = attrTitle
                cfg.image = symbol
                cfg.imagePadding = 7
                cfg.baseForegroundColor = colors.foreground
                cfg.baseBackgroundColor = colors.fill
                cfg.cornerStyle = pillCornerMode ? .capsule : .large
                cfg.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 22, bottom: 12, trailing: 22)
                self.configuration = cfg
                self.cornerConfiguration = pillCornerMode
                    ? .capsule()
                    : .corners(radius: .containerConcentric(minimum: MarcoRadii.poster))
                return
            }
            #endif

            var cfg = UIButton.Configuration.filled()
            cfg.attributedTitle = attrTitle
            cfg.image = symbol
            cfg.imagePadding = 7
            cfg.baseBackgroundColor = colors.fill
            cfg.baseForegroundColor = colors.foreground
            cfg.cornerStyle = pillCornerMode ? .capsule : .large
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 22, bottom: 12, trailing: 22)
            self.configuration = cfg
        } else {
            backgroundColor = colors.fill
            tintColor = colors.foreground
            setTitleColor(colors.foreground, for: .normal)
            setTitle(currentTitleText, for: .normal)
            titleLabel?.font = MarcoTypography.bodySemibold
            setImage(symbol, for: .normal)
            contentEdgeInsets = UIEdgeInsets(top: 12, left: 22, bottom: 12, right: 22)
            if symbol != nil {
                imageEdgeInsets = UIEdgeInsets(top: 0, left: -4, bottom: 0, right: 4)
                titleEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: -4)
            } else {
                imageEdgeInsets = .zero
                titleEdgeInsets = .zero
            }
            clipsToBounds = true
        }
    }

    public func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        let preview = UITargetedPreview(view: self)
        return UIPointerStyle(effect: .lift(preview))
    }
}

/// Translucent secondary action pill using native iOS 26 `.glass()`, iOS 15–25 system ultra-thin material,
/// and clean iOS 14 fallback with hairline edge and iPad pointer lift.
public final class MarcoSecondaryGlassButton: UIButton, UIPointerInteractionDelegate {
    public enum Tone {
        /// Adapts to Light/Dark canvas.
        case adaptive
        /// Always light-on-dark translucent glass for full-bleed cinema hero overlays.
        case onDarkBackdrop
    }

    private var tone: Tone
    private var currentTitleText: String
    private var currentSymbolName: String?
    private var pillCornerMode: Bool
    private var blurBackdropView: UIVisualEffectView?

    public init(
        title: String,
        symbolName: String? = nil,
        tone: Tone = .adaptive,
        isPill: Bool = true
    ) {
        self.tone = tone
        self.currentTitleText = title
        self.currentSymbolName = symbolName
        self.pillCornerMode = isPill
        super.init(frame: .zero)
        commonSetup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func commonSetup() {
        translatesAutoresizingMaskIntoConstraints = false
        adjustsImageWhenHighlighted = false
        layer.cornerCurve = .continuous
        addInteraction(UIPointerInteraction(delegate: self))
        ensureFallbackBlurBackdropIfNeeded()
        rebuildAppearance()
    }

    private var usesNativeGlass26: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return !UIAccessibility.isReduceTransparencyEnabled
        }
        #endif
        return false
    }

    private func ensureFallbackBlurBackdropIfNeeded() {
        guard !usesNativeGlass26 else {
            blurBackdropView?.removeFromSuperview()
            blurBackdropView = nil
            return
        }
        if blurBackdropView == nil {
            let blurStyle: UIBlurEffect.Style = (tone == .onDarkBackdrop)
                ? .systemUltraThinMaterialDark
                : .systemUltraThinMaterial
            let effectView = UIVisualEffectView(effect: UIBlurEffect(style: blurStyle))
            effectView.isUserInteractionEnabled = false
            effectView.layer.cornerCurve = .continuous
            effectView.clipsToBounds = true
            insertSubview(effectView, at: 0)
            blurBackdropView = effectView
        }
    }

    public func setContent(title: String, symbolName: String? = nil) {
        currentTitleText = title
        currentSymbolName = symbolName
        rebuildAppearance()
    }

    public func setTone(_ newTone: Tone) {
        tone = newTone
        blurBackdropView?.removeFromSuperview()
        blurBackdropView = nil
        ensureFallbackBlurBackdropIfNeeded()
        rebuildAppearance()
    }

    public override var intrinsicContentSize: CGSize {
        let base = super.intrinsicContentSize
        let minWidth: CGFloat = currentTitleText.isEmpty ? 46 : 84
        return CGSize(width: max(base.width, minWidth), height: max(base.height, 46))
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let radius = pillCornerMode ? bounds.height * 0.5 : MarcoRadii.poster
        if let blur = blurBackdropView {
            blur.frame = bounds
            blur.layer.cornerRadius = radius
            blur.layer.cornerCurve = .continuous
            sendSubviewToBack(blur)
        }
        if !usesNativeGlass26 {
            layer.cornerRadius = radius
            layer.cornerCurve = .continuous
        }
    }

    public override var isHighlighted: Bool {
        didSet {
            guard !UIAccessibility.isReduceMotionEnabled else {
                alpha = isHighlighted ? 0.78 : 1.0
                return
            }
            UIView.animate(
                withDuration: isHighlighted ? 0.12 : 0.24,
                delay: 0,
                usingSpringWithDamping: 0.78,
                initialSpringVelocity: 0.3,
                options: [.allowUserInteraction, .beginFromCurrentState],
                animations: {
                    self.transform = self.isHighlighted
                        ? CGAffineTransform(scaleX: 0.965, y: 0.965)
                        : .identity
                    self.alpha = self.isHighlighted ? 0.85 : 1.0
                }
            )
        }
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            rebuildAppearance()
        }
    }

    private func resolvedForeground() -> UIColor {
        tone == .onDarkBackdrop ? .white : MarcoColors.primaryText
    }

    private func rebuildAppearance() {
        let foreground = resolvedForeground()
        let symbol = currentSymbolName.flatMap {
            MarcoSymbols.image($0, pointSize: 15, weight: .semibold)
        }
        let isIconOnly = currentTitleText.isEmpty

        if #available(iOS 15.0, *) {
            var attrTitle: AttributedString?
            if !isIconOnly {
                var attr = AttributedString(currentTitleText)
                attr.font = MarcoTypography.bodySemibold
                attrTitle = attr
            }

            #if compiler(>=6.2)
            if #available(iOS 26.0, *), !UIAccessibility.isReduceTransparencyEnabled {
                var cfg = UIButton.Configuration.glass()
                cfg.attributedTitle = attrTitle
                cfg.image = symbol
                cfg.imagePadding = isIconOnly ? 0 : 7
                cfg.baseForegroundColor = foreground
                if tone == .onDarkBackdrop {
                    cfg.baseBackgroundColor = UIColor(white: 0.12, alpha: 0.28)
                }
                cfg.cornerStyle = pillCornerMode ? .capsule : .large
                cfg.contentInsets = isIconOnly
                    ? NSDirectionalEdgeInsets(top: 11, leading: 11, bottom: 11, trailing: 11)
                    : NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
                self.configuration = cfg
                self.cornerConfiguration = pillCornerMode
                    ? .capsule()
                    : .corners(radius: .containerConcentric(minimum: MarcoRadii.poster))
                layer.borderWidth = 0
                return
            }
            #endif

            var cfg = UIButton.Configuration.plain()
            cfg.attributedTitle = attrTitle
            cfg.image = symbol
            cfg.imagePadding = isIconOnly ? 0 : 7
            cfg.baseForegroundColor = foreground
            cfg.contentInsets = isIconOnly
                ? NSDirectionalEdgeInsets(top: 11, leading: 11, bottom: 11, trailing: 11)
                : NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
            self.configuration = cfg
            let borderTint: UIColor = (tone == .onDarkBackdrop)
                ? UIColor.white.withAlphaComponent(0.18)
                : UIColor.separator.withAlphaComponent(0.18)
            applyHairlineBorder(color: borderTint)
        } else {
            tintColor = foreground
            setTitleColor(foreground, for: .normal)
            setTitle(isIconOnly ? nil : currentTitleText, for: .normal)
            titleLabel?.font = MarcoTypography.bodySemibold
            setImage(symbol, for: .normal)
            contentEdgeInsets = isIconOnly
                ? UIEdgeInsets(top: 11, left: 11, bottom: 11, right: 11)
                : UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
            if !isIconOnly && symbol != nil {
                imageEdgeInsets = UIEdgeInsets(top: 0, left: -4, bottom: 0, right: 4)
                titleEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: -4)
            } else {
                imageEdgeInsets = .zero
                titleEdgeInsets = .zero
            }
            let borderTint: UIColor = (tone == .onDarkBackdrop)
                ? UIColor.white.withAlphaComponent(0.18)
                : UIColor.separator.withAlphaComponent(0.18)
            applyHairlineBorder(color: borderTint)
        }
    }

    public func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        let preview = UITargetedPreview(view: self)
        return UIPointerStyle(effect: .lift(preview))
    }
}
