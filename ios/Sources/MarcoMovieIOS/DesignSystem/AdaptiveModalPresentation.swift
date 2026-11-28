// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Adaptive iPhone/iPadOS Modal Presentation & iOS 18+ Zoom Transitions

import UIKit

// MARK: - Modal Sheet Configuration

public enum MarcoModalDetent: Equatable, Sendable {
    case medium
    case large
    /// Custom height fraction (`0.2...1.0`); uses iOS 16+ `.custom` detent and falls back to `.medium` on iOS 15.
    case fraction(CGFloat)
    /// Fixed point height; uses iOS 16+ `.custom` detent and falls back to `.medium` on iOS 15.
    case fixedHeight(CGFloat)
}

public struct MarcoModalOptions {
    /// Compact-width (iPhone) sheet detents on iOS 15+.
    public var detents: [MarcoModalDetent]
    /// Compact centered `.formSheet` size used on iPad / regular horizontal size class.
    public var preferredFormSheetSize: CGSize
    public var prefersGrabberVisible: Bool
    public var preferredCornerRadius: CGFloat
    public var prefersScrollingExpandsWhenScrolledToEdge: Bool
    public var largestUndimmedDetent: MarcoModalDetent?

    /// Optional popover anchor on iPad. When `sourceView` or `barButtonItem` is set on regular width,
    /// presentation automatically upgrades to a crisp `UIPopoverPresentationController`.
    public var sourceView: UIView?
    public var sourceRect: CGRect?
    public var barButtonItem: UIBarButtonItem?
    public var permittedArrowDirections: UIPopoverArrowDirection

    /// Optional convenience wrapper to embed the presented controller inside a `UINavigationController`.
    public var wrapInNavigationController: Bool

    /// Optional adaptive presentation delegate attached *after* `modalPresentationStyle` is configured,
    /// guaranteeing swipe-to-dismiss callbacks fire reliably on `.formSheet`, `.pageSheet`, and `.popover`.
    public weak var presentationDelegate: UIAdaptivePresentationControllerDelegate?

    public init(
        detents: [MarcoModalDetent] = [.medium, .large],
        preferredFormSheetSize: CGSize = CGSize(width: 540, height: 620),
        prefersGrabberVisible: Bool = true,
        preferredCornerRadius: CGFloat = MarcoRadii.sheet,
        prefersScrollingExpandsWhenScrolledToEdge: Bool = true,
        largestUndimmedDetent: MarcoModalDetent? = nil,
        sourceView: UIView? = nil,
        sourceRect: CGRect? = nil,
        barButtonItem: UIBarButtonItem? = nil,
        permittedArrowDirections: UIPopoverArrowDirection = .any,
        wrapInNavigationController: Bool = false,
        presentationDelegate: UIAdaptivePresentationControllerDelegate? = nil
    ) {
        self.detents = detents
        self.preferredFormSheetSize = preferredFormSheetSize
        self.prefersGrabberVisible = prefersGrabberVisible
        self.preferredCornerRadius = preferredCornerRadius
        self.prefersScrollingExpandsWhenScrolledToEdge = prefersScrollingExpandsWhenScrolledToEdge
        self.largestUndimmedDetent = largestUndimmedDetent
        self.sourceView = sourceView
        self.sourceRect = sourceRect
        self.barButtonItem = barButtonItem
        self.permittedArrowDirections = permittedArrowDirections
        self.wrapInNavigationController = wrapInNavigationController
        self.presentationDelegate = presentationDelegate
    }
}

// MARK: - Adaptive Modal Presenter

public enum MarcoModalPresenter {
    /// Resolves the topmost currently visible controller from a host root.
    public static func topPresenter(from root: UIViewController) -> UIViewController {
        var current = root
        while let presented = current.presentedViewController, !presented.isBeingDismissed {
            current = presented
        }
        return current
    }

    /// Presents `viewController` with true iPhone vs iPadOS ergonomics:
    /// - iPad / `.regular`: anchored `UIPopoverPresentationController` (when anchor provided) or centered `.formSheet` (`540x620` default).
    /// - iPhone / `.compact`: iOS 15+ `UISheetPresentationController` with configurable detents (and iOS 16+ custom detents), falling back cleanly to `.pageSheet` on iOS 14.
    @discardableResult
    public static func present(
        _ viewController: UIViewController,
        from presenter: UIViewController,
        options: MarcoModalOptions = MarcoModalOptions(),
        animated: Bool = true,
        completion: (() -> Void)? = nil
    ) -> UIViewController {
        let host = topPresenter(from: presenter)
        let target: UIViewController
        if options.wrapInNavigationController && !(viewController is UINavigationController) {
            let nav = UINavigationController(rootViewController: viewController)
            target = nav
        } else {
            target = viewController
        }

        target.overrideUserInterfaceStyle = MarcoThemeManager.shared.currentInterfaceStyle
        let isRegularWidth = host.traitCollection.horizontalSizeClass == .regular

        if isRegularWidth {
            if options.barButtonItem != nil || options.sourceView != nil {
                target.modalPresentationStyle = .popover
                target.preferredContentSize = options.preferredFormSheetSize
                if let popover = target.popoverPresentationController {
                    popover.permittedArrowDirections = options.permittedArrowDirections
                    if let barButtonItem = options.barButtonItem {
                        popover.barButtonItem = barButtonItem
                    } else if let sourceView = options.sourceView {
                        popover.sourceView = sourceView
                        popover.sourceRect = options.sourceRect ?? sourceView.bounds
                    }
                }
            } else {
                target.modalPresentationStyle = .formSheet
                target.preferredContentSize = options.preferredFormSheetSize
            }
        } else {
            target.modalPresentationStyle = .pageSheet
            if #available(iOS 15.0, *), let sheet = target.sheetPresentationController {
                let mappedDetents = options.detents.map { makeSheetDetent(for: $0) }
                sheet.detents = mappedDetents.isEmpty ? [.medium(), .large()] : mappedDetents
                sheet.prefersGrabberVisible = options.prefersGrabberVisible
                sheet.preferredCornerRadius = options.preferredCornerRadius
                sheet.prefersScrollingExpandsWhenScrolledToEdge = options.prefersScrollingExpandsWhenScrolledToEdge
                if let undimmed = options.largestUndimmedDetent {
                    sheet.largestUndimmedDetentIdentifier = sheetIdentifier(for: undimmed)
                }
            }
        }

        if let delegate = options.presentationDelegate {
            target.presentationController?.delegate = delegate
        }

        host.present(target, animated: animated, completion: completion)
        return target
    }

    @available(iOS 15.0, *)
    private static func makeSheetDetent(for detent: MarcoModalDetent) -> UISheetPresentationController.Detent {
        switch detent {
        case .medium:
            return .medium()
        case .large:
            return .large()
        case .fraction(let value):
            let clamped = min(max(value, 0.2), 1.0)
            if #available(iOS 16.0, *) {
                let id = UISheetPresentationController.Detent.Identifier("marco.fraction.\(Int(clamped * 100))")
                return .custom(identifier: id) { context in
                    context.maximumDetentValue * clamped
                }
            }
            return clamped >= 0.78 ? .large() : .medium()
        case .fixedHeight(let height):
            let clampedHeight = max(height, 220)
            if #available(iOS 16.0, *) {
                let id = UISheetPresentationController.Detent.Identifier("marco.height.\(Int(clampedHeight))")
                return .custom(identifier: id) { context in
                    min(clampedHeight, context.maximumDetentValue)
                }
            }
            return clampedHeight >= 560 ? .large() : .medium()
        }
    }

    @available(iOS 15.0, *)
    private static func sheetIdentifier(for detent: MarcoModalDetent) -> UISheetPresentationController.Detent.Identifier {
        switch detent {
        case .medium:
            return .medium
        case .large:
            return .large
        case .fraction(let value):
            let clamped = min(max(value, 0.2), 1.0)
            if #available(iOS 16.0, *) {
                return UISheetPresentationController.Detent.Identifier("marco.fraction.\(Int(clamped * 100))")
            }
            return clamped >= 0.78 ? .large : .medium
        case .fixedHeight(let height):
            let clampedHeight = max(height, 220)
            if #available(iOS 16.0, *) {
                return UISheetPresentationController.Detent.Identifier("marco.height.\(Int(clampedHeight))")
            }
            return clampedHeight >= 560 ? .large : .medium
        }
    }
}

// MARK: - iOS 18+ Zoom Transition Helper

/// Attaches fluid iOS 18+ Apple TV-style poster zoom transitions with graceful fallback on iOS 14–17.
public enum MarcoZoomTransitionHelper {
    /// Configures `destination.preferredTransition = .zoom(...)` on iOS 18+ so the detail screen zooms
    /// directly out of the tapped poster card, and performs a clean no-op on iOS 14–17.
    public static func configureZoomTransition(
        for destination: UIViewController,
        dimmingColor: UIColor? = nil,
        sourceViewProvider: @escaping () -> UIView?
    ) {
        if #available(iOS 18.0, *) {
            let options = UIViewController.Transition.ZoomOptions()
            if let dimmingColor = dimmingColor {
                options.dimmingColor = dimmingColor
            }
            destination.preferredTransition = .zoom(options: options) { _ in
                sourceViewProvider()
            }
        }
    }

    /// Configures zoom transition on iOS 18+ and pushes `destination` onto `navigationController`.
    public static func push(
        _ destination: UIViewController,
        on navigationController: UINavigationController?,
        from sourceViewProvider: @escaping () -> UIView?,
        animated: Bool = true
    ) {
        configureZoomTransition(for: destination, sourceViewProvider: sourceViewProvider)
        navigationController?.pushViewController(destination, animated: animated)
    }

    /// Configures zoom transition on iOS 18+ and presents `destination` modally from `presenter`.
    public static func present(
        _ destination: UIViewController,
        from presenter: UIViewController,
        sourceViewProvider: @escaping () -> UIView?,
        animated: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        configureZoomTransition(for: destination, sourceViewProvider: sourceViewProvider)
        MarcoModalPresenter.topPresenter(from: presenter).present(
            destination,
            animated: animated,
            completion: completion
        )
    }
}
