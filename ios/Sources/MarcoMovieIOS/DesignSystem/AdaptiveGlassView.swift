// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Adaptive Liquid Glass (iOS 26+) & System Material Surface (iOS 14–25)

import UIKit

public enum MarcoGlassStyle: Equatable, Sendable {
    /// Standard translucent chrome surface for floating panels, bars, and sheets.
    case chrome
    /// Lightest airy glass surface for media overlays and subtle pills.
    case ultraThin
    /// Capsule-shaped translucent glass pill (auto-updates radius to height / 2).
    case capsule
}

/// Reusable translucent surface that renders genuine hardware-refractive `UIGlassEffect` on iOS 26+
/// and crisp system materials with a single subtle hairline edge on iOS 14–25.
public final class MarcoGlassSurfaceView: UIView {
    public private(set) var style: MarcoGlassStyle
    public let isInteractive: Bool

    public var cornerRadius: CGFloat {
        didSet {
            applyGeometry()
        }
    }

    private let effectView: UIVisualEffectView

    /// Add all foreground subviews to `contentView`.
    public var contentView: UIView {
        effectView.contentView
    }

    public init(
        style: MarcoGlassStyle = .chrome,
        cornerRadius: CGFloat = MarcoRadii.card,
        isInteractive: Bool = false
    ) {
        self.style = style
        self.cornerRadius = cornerRadius
        self.isInteractive = isInteractive
        self.effectView = UIVisualEffectView(effect: Self.makeEffect(for: style, isInteractive: isInteractive))
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func usesNativeGlass26() -> Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return !UIAccessibility.isReduceTransparencyEnabled
        }
        #endif
        return false
    }

    private static func makeEffect(for style: MarcoGlassStyle, isInteractive: Bool) -> UIVisualEffect {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), !UIAccessibility.isReduceTransparencyEnabled {
            let glass = UIGlassEffect(style: style == .ultraThin ? .clear : .regular)
            glass.isInteractive = isInteractive
            return glass
        }
        #endif

        switch style {
        case .chrome, .capsule:
            return UIBlurEffect(style: .systemChromeMaterial)
        case .ultraThin:
            return UIBlurEffect(style: .systemUltraThinMaterial)
        }
    }

    private func setup() {
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = false

        effectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleReduceTransparencyChanged),
            name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
            object: nil
        )

        applyGeometry()
        applyBorder()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func updateStyle(_ newStyle: MarcoGlassStyle) {
        guard style != newStyle else { return }
        style = newStyle
        effectView.effect = Self.makeEffect(for: newStyle, isInteractive: isInteractive)
        applyGeometry()
        applyBorder()
    }

    @objc private func handleReduceTransparencyChanged() {
        effectView.effect = Self.makeEffect(for: style, isInteractive: isInteractive)
        applyGeometry()
        applyBorder()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        if style == .capsule && !Self.usesNativeGlass26() {
            let radius = min(bounds.width, bounds.height) * 0.5
            effectView.layer.cornerRadius = radius
            effectView.layer.cornerCurve = .continuous
        }
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyBorder()
        }
    }

    private func applyGeometry() {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), !UIAccessibility.isReduceTransparencyEnabled {
            if style == .capsule {
                effectView.cornerConfiguration = .capsule()
            } else {
                effectView.cornerConfiguration = .corners(
                    radius: .containerConcentric(minimum: max(cornerRadius, 8))
                )
            }
            return
        }
        #endif

        let resolvedRadius = (style == .capsule)
            ? min(bounds.width, bounds.height) * 0.5
            : cornerRadius
        effectView.layer.cornerRadius = resolvedRadius
        effectView.layer.cornerCurve = .continuous
        effectView.clipsToBounds = true
    }

    private func applyBorder() {
        // Native iOS 26 UIGlassEffect renders its own optical specular edge; avoid double borders.
        if Self.usesNativeGlass26() {
            effectView.layer.borderWidth = 0
            effectView.layer.borderColor = nil
            return
        }
        let scale = window?.screen.scale ?? UIScreen.main.scale
        effectView.layer.borderWidth = 1.0 / max(scale, 1.0)
        effectView.layer.borderColor = UIColor.separator
            .resolvedColor(with: traitCollection)
            .withAlphaComponent(0.18)
            .cgColor
    }
}

/// Container that coordinates optical Liquid Glass merging across sibling glass controls on iOS 26+
/// (`UIGlassContainerEffect`) and acts as a clean transparent pass-through container on iOS 14–25.
public final class MarcoGlassContainerView: UIView {
    public var spacing: CGFloat {
        didSet {
            updateContainerSpacing()
        }
    }

    private let effectContainerView: UIVisualEffectView?
    private let fallbackContainerView = UIView()

    /// Place sibling `MarcoGlassSurfaceView` / `MarcoSecondaryGlassButton` views inside `contentView`.
    public var contentView: UIView {
        effectContainerView?.contentView ?? fallbackContainerView
    }

    public init(spacing: CGFloat = 10.0) {
        self.spacing = spacing
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let effect = UIGlassContainerEffect()
            effect.spacing = spacing
            self.effectContainerView = UIVisualEffectView(effect: effect)
        } else {
            self.effectContainerView = nil
        }
        #else
        self.effectContainerView = nil
        #endif
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = false

        let host: UIView = effectContainerView ?? fallbackContainerView
        host.translatesAutoresizingMaskIntoConstraints = false
        host.backgroundColor = .clear
        host.isOpaque = false
        host.clipsToBounds = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: topAnchor),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func updateContainerSpacing() {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *),
           let containerEffect = effectContainerView?.effect as? UIGlassContainerEffect {
            containerEffect.spacing = spacing
        }
        #endif
    }
}
