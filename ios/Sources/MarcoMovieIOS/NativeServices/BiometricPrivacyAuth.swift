// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — LocalAuthentication Biometrics & Pure UIKit Privacy Space PIN Controller

import LocalAuthentication
import UIKit

// MARK: - Biometric Authentication Helper

public enum BiometricKind: Equatable, Sendable {
    case none
    case touchID
    case faceID
    case opticID

    public var displayName: String {
        switch self {
        case .faceID: return "面容 ID"
        case .touchID: return "触控 ID"
        case .opticID: return "Optic ID"
        case .none: return "生物识别"
        }
    }

    public var symbolName: String {
        switch self {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        case .none: return "lock.shield"
        }
    }
}

public enum BiometricAuthOutcome: Equatable, Sendable {
    case authenticated
    case cancelled
    case fallbackToPin
    case notAvailable(String)
    case failed(String)
}

public enum BiometricPrivacyAuth {
    /// Inspects the device's available biometric hardware without prompting the user.
    public static func availableBiometry() -> BiometricKind {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        if #available(iOS 17.0, *), context.biometryType == .opticID {
            return .opticID
        }
        switch context.biometryType {
        case .faceID:
            return .faceID
        case .touchID:
            return .touchID
        default:
            return .none
        }
    }

    public static func isBiometricAvailable() -> Bool {
        availableBiometry() != .none
    }

    /// Evaluates Face ID / Touch ID (or device authentication if requested) via `LAContext`.
    /// Completion is always delivered on the main queue.
    public static func authenticate(
        reason: String = "验证身份以进入私密空间",
        allowDevicePasscodeFallback: Bool = false,
        fallbackButtonTitle: String? = "使用 PIN 码",
        completion: @escaping (BiometricAuthOutcome) -> Void
    ) {
        let context = LAContext()
        context.localizedFallbackTitle = fallbackButtonTitle
        context.localizedCancelTitle = "取消"

        let policy: LAPolicy = allowDevicePasscodeFallback
            ? .deviceOwnerAuthentication
            : .deviceOwnerAuthenticationWithBiometrics

        var authError: NSError?
        guard context.canEvaluatePolicy(policy, error: &authError) else {
            let message = authError?.localizedDescription ?? "当前设备不支持或未启用生物识别"
            DispatchQueue.main.async {
                completion(.notAvailable(message))
            }
            return
        }

        context.evaluatePolicy(policy, localizedReason: reason) { success, error in
            DispatchQueue.main.async {
                if success {
                    completion(.authenticated)
                    return
                }
                guard let laError = error as? LAError else {
                    completion(.failed(error?.localizedDescription ?? "身份验证未通过"))
                    return
                }
                switch laError.code {
                case .userCancel, .systemCancel, .appCancel:
                    completion(.cancelled)
                case .userFallback:
                    completion(.fallbackToPin)
                case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                    completion(.notAvailable(laError.localizedDescription))
                default:
                    completion(.failed(laError.localizedDescription))
                }
            }
        }
    }

    /// Swift concurrency wrapper backed by iOS 14-compatible completion bridging.
    public static func authenticate(
        reason: String = "验证身份以进入私密空间",
        allowDevicePasscodeFallback: Bool = false,
        fallbackButtonTitle: String? = "使用 PIN 码"
    ) async -> BiometricAuthOutcome {
        await withCheckedContinuation { continuation in
            authenticate(
                reason: reason,
                allowDevicePasscodeFallback: allowDevicePasscodeFallback,
                fallbackButtonTitle: fallbackButtonTitle
            ) { outcome in
                continuation.resume(returning: outcome)
            }
        }
    }
}

// MARK: - Privacy PIN Types

public enum PrivacyPinMode: Equatable, Sendable {
    /// First-time PIN creation with 2-step enter + confirm verification.
    case setup
    /// Verify existing PIN (with optional Face ID / Touch ID unlock).
    case verify
}

public enum PrivacyPinResult: Equatable, Sendable {
    /// Setup completed with the newly confirmed PIN string.
    case created(String)
    /// PIN matched successfully in `.verify` mode.
    case verified
    /// Unlocked via Face ID / Touch ID in `.verify` mode.
    case biometricUnlocked
    /// User dismissed or tapped Cancel.
    case cancelled
}

// MARK: - Thread-Safe Result Delivery Box

private final class PinCompletionBox {
    private let lock = NSLock()
    private var handler: ((PrivacyPinResult) -> Void)?

    init(_ handler: ((PrivacyPinResult) -> Void)?) {
        self.handler = handler
    }

    func set(_ handler: ((PrivacyPinResult) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func fireOnce(_ result: PrivacyPinResult) {
        let cb: ((PrivacyPinResult) -> Void)?
        lock.lock()
        cb = handler
        handler = nil
        lock.unlock()
        guard let cb = cb else { return }
        if Thread.isMainThread {
            cb(result)
        } else {
            DispatchQueue.main.async { cb(result) }
        }
    }
}

// MARK: - Tactile Continuous-Corner Keypad Button

private final class PrivacyKeypadButton: UIButton, UIPointerInteractionDelegate {
    private var isSymbolOnly: Bool

    init(digit: String) {
        self.isSymbolOnly = false
        super.init(frame: .zero)
        setupBase()
        setTitle(digit, for: .normal)
        titleLabel?.font = MarcoTypography.monospacedDigits(size: 27, weight: .medium, textStyle: .title1)
        setTitleColor(MarcoColors.primaryText, for: .normal)
        backgroundColor = MarcoColors.subtleFill
    }

    init(symbolName: String, accessibilityLabel: String) {
        self.isSymbolOnly = true
        super.init(frame: .zero)
        setupBase()
        self.accessibilityLabel = accessibilityLabel
        let icon = MarcoSymbols.image(
            symbolName,
            pointSize: 21,
            weight: .medium,
            hierarchicalColor: MarcoColors.primaryText
        )
        setImage(icon, for: .normal)
        tintColor = MarcoColors.primaryText
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupBase() {
        translatesAutoresizingMaskIntoConstraints = false
        adjustsImageWhenHighlighted = false
        layer.cornerCurve = .continuous
        addInteraction(UIPointerInteraction(delegate: self))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = isSymbolOnly ? 16 : min(bounds.width, bounds.height) * 0.36
        layer.cornerCurve = .continuous
    }

    override var isHighlighted: Bool {
        didSet {
            guard !UIAccessibility.isReduceMotionEnabled else {
                alpha = isHighlighted ? 0.65 : 1.0
                return
            }
            UIView.animate(
                withDuration: isHighlighted ? 0.08 : 0.22,
                delay: 0,
                usingSpringWithDamping: 0.78,
                initialSpringVelocity: 0.3,
                options: [.allowUserInteraction, .beginFromCurrentState],
                animations: {
                    self.transform = self.isHighlighted
                        ? CGAffineTransform(scaleX: 0.92, y: 0.92)
                        : .identity
                    self.alpha = self.isHighlighted ? 0.72 : 1.0
                }
            )
        }
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        let preview = UITargetedPreview(view: self)
        return UIPointerStyle(effect: .highlight(preview))
    }
}

// MARK: - Pure UIKit Privacy PIN View Controller

/// Sleek Apple-native PIN setup (set + confirm) and verification sheet with custom tactile keypad,
/// haptic feedback, optional Face ID / Touch ID unlock, Magic Keyboard digit shortcuts,
/// and adaptive presentation (`.formSheet` on iPad, `.medium`/custom sheet on iPhone).
public final class PrivacyPinViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    public let mode: PrivacyPinMode
    public let pinLength: Int
    public let allowsBiometrics: Bool
    public let autoPromptBiometrics: Bool
    public let biometricReason: String

    /// Called in `.verify` mode to validate the entered PIN against caller-managed Keychain/hash storage.
    public var verifyHandler: ((String) -> Bool)?

    /// Invoked once on completion or dismissal.
    public var onComplete: ((PrivacyPinResult) -> Void)? {
        didSet {
            completionBox.set(onComplete)
        }
    }

    private let completionBox: PinCompletionBox
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private var finished = false
    private var firstStepPin: String?
    private var enteredDigits = ""
    private var isProcessingTransition = false
    private var didAutoPromptBiometrics = false

    private let headerIconBadge = UIView()
    private let headerIconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let dotsStack = UIStackView()
    private var dotViews: [UIView] = []
    private let errorLabel = UILabel()
    private var biometricButton: PrivacyKeypadButton?
    private var backspaceButton: PrivacyKeypadButton?

    private let availableBiometry: BiometricKind

    public init(
        mode: PrivacyPinMode,
        pinLength: Int = 4,
        allowsBiometrics: Bool = true,
        autoPromptBiometrics: Bool = true,
        biometricReason: String = "验证身份以进入私密空间",
        verifyHandler: ((String) -> Bool)? = nil,
        onComplete: ((PrivacyPinResult) -> Void)? = nil
    ) {
        self.mode = mode
        self.pinLength = min(max(pinLength, 4), 6)
        self.availableBiometry = BiometricPrivacyAuth.availableBiometry()
        self.allowsBiometrics = allowsBiometrics && (mode == .verify) && (self.availableBiometry != .none)
        self.autoPromptBiometrics = autoPromptBiometrics
        self.biometricReason = biometricReason
        self.verifyHandler = verifyHandler
        self.onComplete = onComplete
        self.completionBox = PinCompletionBox(onComplete)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        completionBox.fireOnce(.cancelled)
    }

    /// Presents the PIN sheet adaptively: compact `.formSheet` (440x580) on iPad, `.fraction(0.78)`/`.medium` sheet on iPhone.
    public static func present(
        from host: UIViewController,
        mode: PrivacyPinMode,
        pinLength: Int = 4,
        allowsBiometrics: Bool = true,
        autoPromptBiometrics: Bool = true,
        biometricReason: String = "验证身份以进入私密空间",
        verifyHandler: ((String) -> Bool)? = nil,
        onComplete: @escaping (PrivacyPinResult) -> Void
    ) {
        let vc = PrivacyPinViewController(
            mode: mode,
            pinLength: pinLength,
            allowsBiometrics: allowsBiometrics,
            autoPromptBiometrics: autoPromptBiometrics,
            biometricReason: biometricReason,
            verifyHandler: verifyHandler,
            onComplete: onComplete
        )
        let nav = UINavigationController(rootViewController: vc)
        let options = MarcoModalOptions(
            detents: [.fixedHeight(500), .large],
            preferredFormSheetSize: CGSize(width: 440, height: 540),
            prefersGrabberVisible: true,
            preferredCornerRadius: MarcoRadii.sheet,
            wrapInNavigationController: false,
            presentationDelegate: vc
        )
        MarcoModalPresenter.present(nav, from: host, options: options)
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = MarcoThemeManager.shared.currentInterfaceStyle
        view.backgroundColor = MarcoColors.canvasBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "取消",
            style: .plain,
            target: self,
            action: #selector(cancelTapped)
        )
        lightImpact.prepare()
        setupLayout()
        updateHeaderText()
        refreshDots(animatedIndex: nil)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if allowsBiometrics && autoPromptBiometrics && !didAutoPromptBiometrics {
            didAutoPromptBiometrics = true
            triggerBiometricAuthentication()
        }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            finish(with: .cancelled, dismissModal: false)
        }
    }

    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finish(with: .cancelled, dismissModal: false)
    }

    // MARK: - Hardware Keyboard Support (iPad Magic Keyboard)

    public override var canBecomeFirstResponder: Bool { true }

    public override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = (0...9).map { digit in
            UIKeyCommand(
                input: "\(digit)",
                modifierFlags: [],
                action: #selector(handleKeyboardDigit(_:))
            )
        }
        commands.append(UIKeyCommand(
            input: "\u{8}",
            modifierFlags: [],
            action: #selector(backspaceTapped)
        ))
        commands.append(UIKeyCommand(
            input: UIKeyCommand.inputEscape,
            modifierFlags: [],
            action: #selector(cancelTapped)
        ))
        return commands
    }

    @objc private func handleKeyboardDigit(_ command: UIKeyCommand) {
        guard let input = command.input, !input.isEmpty else { return }
        appendDigit(input)
    }

    // MARK: - Layout Construction

    private func setupLayout() {
        headerIconBadge.translatesAutoresizingMaskIntoConstraints = false
        headerIconBadge.backgroundColor = MarcoColors.subtleFill
        headerIconBadge.applyContinuousCorners(16)
        view.addSubview(headerIconBadge)

        headerIconView.translatesAutoresizingMaskIntoConstraints = false
        headerIconView.image = MarcoSymbols.image(
            mode == .setup ? "lock.badge.plus" : "lock.shield.fill",
            pointSize: 24,
            weight: .semibold,
            hierarchicalColor: MarcoColors.accentTint
        ) ?? MarcoSymbols.image(
            "lock.fill",
            pointSize: 24,
            weight: .semibold,
            hierarchicalColor: MarcoColors.accentTint
        )
        headerIconView.contentMode = .scaleAspectFit
        headerIconBadge.addSubview(headerIconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = MarcoTypography.sectionHeader
        titleLabel.textColor = MarcoColors.primaryText
        titleLabel.textAlignment = .center
        view.addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = MarcoTypography.cardSubtitle
        subtitleLabel.textColor = MarcoColors.secondaryText
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 2
        view.addSubview(subtitleLabel)

        dotsStack.translatesAutoresizingMaskIntoConstraints = false
        dotsStack.axis = .horizontal
        dotsStack.spacing = 18
        dotsStack.alignment = .center
        dotsStack.distribution = .equalSpacing
        view.addSubview(dotsStack)

        for _ in 0..<pinLength {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.applyContinuousCorners(7)
            dot.backgroundColor = .clear
            dot.layer.borderWidth = 1.6
            dot.layer.borderColor = MarcoColors.tertiaryText.cgColor
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 14),
                dot.heightAnchor.constraint(equalToConstant: 14),
            ])
            dotsStack.addArrangedSubview(dot)
            dotViews.append(dot)
        }

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = MarcoTypography.caption
        errorLabel.textColor = MarcoColors.destructive
        errorLabel.textAlignment = .center
        errorLabel.text = " "
        errorLabel.alpha = 0
        view.addSubview(errorLabel)

        let keypadGrid = buildKeypadGrid()
        keypadGrid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keypadGrid)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            headerIconBadge.topAnchor.constraint(equalTo: guide.topAnchor, constant: 4),
            headerIconBadge.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            headerIconBadge.widthAnchor.constraint(equalToConstant: 46),
            headerIconBadge.heightAnchor.constraint(equalToConstant: 46),

            headerIconView.centerXAnchor.constraint(equalTo: headerIconBadge.centerXAnchor),
            headerIconView.centerYAnchor.constraint(equalTo: headerIconBadge.centerYAnchor),

            titleLabel.topAnchor.constraint(equalTo: headerIconBadge.bottomAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 28),
            subtitleLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -28),

            dotsStack.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 16),
            dotsStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            dotsStack.heightAnchor.constraint(equalToConstant: 18),

            errorLabel.topAnchor.constraint(equalTo: dotsStack.bottomAnchor, constant: 6),
            errorLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            errorLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),

            keypadGrid.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 10),
            keypadGrid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            keypadGrid.widthAnchor.constraint(equalToConstant: 262),
            keypadGrid.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -12),
        ])
    }

    private func buildKeypadGrid() -> UIStackView {
        let rowsStack = UIStackView()
        rowsStack.axis = .vertical
        rowsStack.spacing = 10
        rowsStack.distribution = .fillEqually

        let digitRows = [
            ["1", "2", "3"],
            ["4", "5", "6"],
            ["7", "8", "9"],
        ]

        for rowDigits in digitRows {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 20
            row.distribution = .fillEqually
            for digit in rowDigits {
                let button = PrivacyKeypadButton(digit: digit)
                button.tag = Int(digit) ?? 0
                button.addTarget(self, action: #selector(digitButtonTapped(_:)), for: .touchUpInside)
                NSLayoutConstraint.activate([
                    button.widthAnchor.constraint(equalToConstant: 74),
                    button.heightAnchor.constraint(equalToConstant: 56),
                ])
                row.addArrangedSubview(button)
            }
            rowsStack.addArrangedSubview(row)
        }

        // Bottom row: [Biometric / Spacer] [0] [Backspace]
        let bottomRow = UIStackView()
        bottomRow.axis = .horizontal
        bottomRow.spacing = 20
        bottomRow.distribution = .fillEqually

        if allowsBiometrics {
            let bioBtn = PrivacyKeypadButton(
                symbolName: availableBiometry.symbolName,
                accessibilityLabel: "使用\(availableBiometry.displayName)解锁"
            )
            bioBtn.addTarget(self, action: #selector(biometricButtonTapped), for: .touchUpInside)
            biometricButton = bioBtn
            NSLayoutConstraint.activate([
                bioBtn.widthAnchor.constraint(equalToConstant: 74),
                bioBtn.heightAnchor.constraint(equalToConstant: 56),
            ])
            bottomRow.addArrangedSubview(bioBtn)
        } else {
            let spacer = UIView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                spacer.widthAnchor.constraint(equalToConstant: 74),
                spacer.heightAnchor.constraint(equalToConstant: 56),
            ])
            bottomRow.addArrangedSubview(spacer)
        }

        let zeroBtn = PrivacyKeypadButton(digit: "0")
        zeroBtn.tag = 0
        zeroBtn.addTarget(self, action: #selector(digitButtonTapped(_:)), for: .touchUpInside)
        NSLayoutConstraint.activate([
            zeroBtn.widthAnchor.constraint(equalToConstant: 74),
            zeroBtn.heightAnchor.constraint(equalToConstant: 56),
        ])
        bottomRow.addArrangedSubview(zeroBtn)

        let delBtn = PrivacyKeypadButton(symbolName: "delete.left", accessibilityLabel: "删除")
        delBtn.addTarget(self, action: #selector(backspaceTapped), for: .touchUpInside)
        backspaceButton = delBtn
        NSLayoutConstraint.activate([
            delBtn.widthAnchor.constraint(equalToConstant: 74),
            delBtn.heightAnchor.constraint(equalToConstant: 56),
        ])
        bottomRow.addArrangedSubview(delBtn)

        rowsStack.addArrangedSubview(bottomRow)
        return rowsStack
    }

    // MARK: - State & Animations

    private func updateHeaderText() {
        switch mode {
        case .setup:
            if firstStepPin == nil {
                titleLabel.text = "设置私密空间密码"
                subtitleLabel.text = "请输入 \(pinLength) 位数字 PIN 码以保护隐私内容"
            } else {
                titleLabel.text = "请再次输入密码"
                subtitleLabel.text = "确认您刚刚设置的 \(pinLength) 位 PIN 码"
            }
        case .verify:
            titleLabel.text = "解锁私密空间"
            subtitleLabel.text = allowsBiometrics
                ? "输入 \(pinLength) 位 PIN 码或轻点\(availableBiometry.displayName)解锁"
                : "请输入 \(pinLength) 位数字 PIN 码"
        }
    }

    private func refreshDots(animatedIndex: Int?) {
        let filledCount = enteredDigits.count
        backspaceButton?.isEnabled = filledCount > 0
        backspaceButton?.alpha = filledCount > 0 ? 1.0 : 0.35

        for (index, dot) in dotViews.enumerated() {
            let isFilled = index < filledCount
            if isFilled {
                dot.backgroundColor = MarcoColors.primaryText
                dot.layer.borderColor = MarcoColors.primaryText.cgColor
            } else {
                dot.backgroundColor = .clear
                dot.layer.borderColor = MarcoColors.tertiaryText
                    .resolvedColor(with: traitCollection)
                    .cgColor
            }
            if let target = animatedIndex, target == index, !UIAccessibility.isReduceMotionEnabled {
                dot.transform = CGAffineTransform(scaleX: 1.32, y: 1.32)
                UIView.animate(
                    withDuration: 0.22,
                    delay: 0,
                    usingSpringWithDamping: 0.6,
                    initialSpringVelocity: 0.4,
                    options: [.allowUserInteraction],
                    animations: {
                        dot.transform = .identity
                    }
                )
            }
        }
    }

    private func showError(_ message: String) {
        MarcoHaptics.error()
        errorLabel.text = message
        UIView.animate(withDuration: 0.16) {
            self.errorLabel.alpha = 1.0
        }
        shakeDots()
    }

    private func clearError() {
        guard errorLabel.alpha > 0 else { return }
        UIView.animate(withDuration: 0.15) {
            self.errorLabel.alpha = 0.0
        }
    }

    private func shakeDots() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.timingFunction = CAMediaTimingFunction(name: .easeOut)
        shake.duration = 0.42
        shake.values = [-12, 12, -9, 9, -5, 5, -2, 2, 0]
        dotsStack.layer.add(shake, forKey: "marcoPinShake")
    }

    // MARK: - Actions

    @objc private func digitButtonTapped(_ sender: UIButton) {
        appendDigit("\(sender.tag)")
    }

    private func appendDigit(_ digit: String) {
        guard !isProcessingTransition, !finished, enteredDigits.count < pinLength else { return }
        lightImpact.impactOccurred()
        lightImpact.prepare()
        clearError()

        let nextIndex = enteredDigits.count
        enteredDigits.append(digit)
        refreshDots(animatedIndex: nextIndex)

        if enteredDigits.count == pinLength {
            isProcessingTransition = true
            let completedPin = enteredDigits
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
                self?.evaluateCompletedPin(completedPin)
            }
        }
    }

    @objc private func backspaceTapped() {
        guard !isProcessingTransition, !finished, !enteredDigits.isEmpty else { return }
        lightImpact.impactOccurred()
        enteredDigits.removeLast()
        refreshDots(animatedIndex: nil)
    }

    @objc private func biometricButtonTapped() {
        MarcoHaptics.selection()
        triggerBiometricAuthentication()
    }

    @objc private func cancelTapped() {
        finish(with: .cancelled, dismissModal: true)
    }

    private func evaluateCompletedPin(_ pin: String) {
        switch mode {
        case .setup:
            if let first = firstStepPin {
                if first == pin {
                    MarcoHaptics.success()
                    MarcoSymbols.bounce(headerIconView)
                    finish(with: .created(pin), dismissModal: true)
                } else {
                    firstStepPin = nil
                    enteredDigits = ""
                    isProcessingTransition = false
                    updateHeaderText()
                    refreshDots(animatedIndex: nil)
                    showError("两次输入的 PIN 码不一致，请重新设置")
                }
            } else {
                firstStepPin = pin
                enteredDigits = ""
                isProcessingTransition = false
                MarcoHaptics.selection()
                UIView.transition(
                    with: view,
                    duration: 0.22,
                    options: [.transitionCrossDissolve],
                    animations: {
                        self.updateHeaderText()
                        self.refreshDots(animatedIndex: nil)
                    }
                )
            }

        case .verify:
            let matched = verifyHandler?(pin) ?? false
            if matched {
                MarcoHaptics.success()
                MarcoSymbols.bounce(headerIconView)
                finish(with: .verified, dismissModal: true)
            } else {
                enteredDigits = ""
                isProcessingTransition = false
                refreshDots(animatedIndex: nil)
                showError("PIN 码错误，请重试")
            }
        }
    }

    private func triggerBiometricAuthentication() {
        guard allowsBiometrics, !finished else { return }
        BiometricPrivacyAuth.authenticate(
            reason: biometricReason,
            allowDevicePasscodeFallback: false,
            fallbackButtonTitle: "输入 PIN 码"
        ) { [weak self] outcome in
            guard let self = self, !self.finished else { return }
            switch outcome {
            case .authenticated:
                MarcoHaptics.success()
                MarcoSymbols.bounce(self.headerIconView)
                self.finish(with: .biometricUnlocked, dismissModal: true)
            case .cancelled, .fallbackToPin:
                break
            case .notAvailable(let message), .failed(let message):
                self.showError(message)
            }
        }
    }

    private func finish(with result: PrivacyPinResult, dismissModal: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.finish(with: result, dismissModal: dismissModal)
            }
            return
        }
        guard !finished else { return }
        finished = true
        let box = completionBox
        let target = navigationController ?? self
        if dismissModal, target.presentingViewController != nil, !target.isBeingDismissed {
            target.dismiss(animated: true) {
                box.fireOnce(result)
            }
        } else {
            box.fireOnce(result)
        }
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            refreshDots(animatedIndex: nil)
        }
    }
}
