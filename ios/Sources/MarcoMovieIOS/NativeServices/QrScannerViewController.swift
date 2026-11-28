// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Pure UIKit QR Code Camera Scanner & High-Resolution CoreImage QR Generator

import AVFoundation
import CoreImage
import UIKit

// MARK: - CoreImage QR Code Generator

public enum MarcoQrCodeGenerator {
    /// Generates a razor-sharp QR code image using CoreImage `CIQRCodeGenerator` with nearest-neighbor scaling.
    public static func image(
        for content: String,
        size: CGSize = CGSize(width: 240, height: 240),
        foregroundColor: UIColor = .black,
        backgroundColor: UIColor = .white,
        correctionLevel: String = "M"
    ) -> UIImage? {
        guard !content.isEmpty,
              let data = content.data(using: .utf8),
              let qrFilter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }

        qrFilter.setValue(data, forKey: "inputMessage")
        qrFilter.setValue(correctionLevel, forKey: "inputCorrectionLevel")
        guard var outputImage = qrFilter.outputImage else { return nil }

        if let colorFilter = CIFilter(name: "CIFalseColor") {
            colorFilter.setValue(outputImage, forKey: kCIInputImageKey)
            colorFilter.setValue(CIColor(color: foregroundColor), forKey: "inputColor0")
            colorFilter.setValue(CIColor(color: backgroundColor), forKey: "inputColor1")
            if let tinted = colorFilter.outputImage {
                outputImage = tinted
            }
        }

        let extent = outputImage.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }

        let targetWidth = max(size.width, 64)
        let targetHeight = max(size.height, 64)
        let scale = UIScreen.main.scale
        let pixelWidth = Int(ceil(targetWidth * scale))
        let pixelHeight = Int(ceil(targetHeight * scale))

        let ciContext = CIContext(options: nil)
        guard let cgSmall = ciContext.createCGImage(outputImage, from: extent) else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let bitmapCtx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        bitmapCtx.interpolationQuality = .none
        bitmapCtx.setFillColor(backgroundColor.cgColor)
        bitmapCtx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        bitmapCtx.draw(cgSmall, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        guard let crispCG = bitmapCtx.makeImage() else { return nil }
        return UIImage(cgImage: crispCG, scale: scale, orientation: .up)
    }
}

// MARK: - Thread-Safe Completion Box

private final class QrScannerCompletionBox {
    private let lock = NSLock()
    private var handler: ((String?) -> Void)?

    init(_ handler: ((String?) -> Void)?) {
        self.handler = handler
    }

    func set(_ handler: ((String?) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func fireOnce(_ value: String?) {
        let cb: ((String?) -> Void)?
        lock.lock()
        cb = handler
        handler = nil
        lock.unlock()
        guard let cb = cb else { return }
        if Thread.isMainThread {
            cb(value)
        } else {
            DispatchQueue.main.async { cb(value) }
        }
    }
}

// MARK: - Translucent Scan Reticle Overlay

private final class QrReticleOverlayView: UIView {
    private let maskLayer = CAShapeLayer()
    private let bracketsLayer = CAShapeLayer()
    private let scanLineLayer = CAGradientLayer()

    private(set) var cutoutRect: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        maskLayer.fillRule = .evenOdd
        maskLayer.fillColor = UIColor.black.withAlphaComponent(0.56).cgColor
        layer.addSublayer(maskLayer)

        bracketsLayer.fillColor = UIColor.clear.cgColor
        bracketsLayer.strokeColor = UIColor.white.withAlphaComponent(0.95).cgColor
        bracketsLayer.lineWidth = 3.2
        bracketsLayer.lineCap = .round
        bracketsLayer.lineJoin = .round
        layer.addSublayer(bracketsLayer)

        scanLineLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
        scanLineLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        scanLineLayer.colors = [
            UIColor.white.withAlphaComponent(0.0).cgColor,
            UIColor.white.withAlphaComponent(0.85).cgColor,
            UIColor.white.withAlphaComponent(0.0).cgColor,
        ]
        scanLineLayer.cornerRadius = 1.0
        layer.addSublayer(scanLineLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(min(bounds.width, bounds.height) * 0.64, 276)
        let centerY = bounds.midY - 26
        let rect = CGRect(
            x: (bounds.width - side) * 0.5,
            y: max(centerY - side * 0.5, safeAreaInsets.top + 28),
            width: side,
            height: side
        )
        cutoutRect = rect

        let fullPath = UIBezierPath(rect: bounds)
        let aperture = UIBezierPath(roundedRect: rect, cornerRadius: 22)
        fullPath.append(aperture)
        maskLayer.path = fullPath.cgPath

        bracketsLayer.path = makeCornerBracketsPath(around: rect, length: 26, radius: 22).cgPath
        updateScanLineAnimation()
    }

    func pulseSuccess() {
        bracketsLayer.strokeColor = MarcoColors.success.cgColor
    }

    private func makeCornerBracketsPath(around rect: CGRect, length: CGFloat, radius: CGFloat) -> UIBezierPath {
        let p = UIBezierPath()
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY

        // Top-left
        p.move(to: CGPoint(x: minX, y: minY + length))
        p.addLine(to: CGPoint(x: minX, y: minY + radius))
        p.addArc(
            withCenter: CGPoint(x: minX + radius, y: minY + radius),
            radius: radius,
            startAngle: .pi,
            endAngle: .pi * 1.5,
            clockwise: true
        )
        p.addLine(to: CGPoint(x: minX + length, y: minY))

        // Top-right
        p.move(to: CGPoint(x: maxX - length, y: minY))
        p.addLine(to: CGPoint(x: maxX - radius, y: minY))
        p.addArc(
            withCenter: CGPoint(x: maxX - radius, y: minY + radius),
            radius: radius,
            startAngle: .pi * 1.5,
            endAngle: 0,
            clockwise: true
        )
        p.addLine(to: CGPoint(x: maxX, y: minY + length))

        // Bottom-right
        p.move(to: CGPoint(x: maxX, y: maxY - length))
        p.addLine(to: CGPoint(x: maxX, y: maxY - radius))
        p.addArc(
            withCenter: CGPoint(x: maxX - radius, y: maxY - radius),
            radius: radius,
            startAngle: 0,
            endAngle: .pi * 0.5,
            clockwise: true
        )
        p.addLine(to: CGPoint(x: maxX - length, y: maxY))

        // Bottom-left
        p.move(to: CGPoint(x: minX + length, y: maxY))
        p.addLine(to: CGPoint(x: minX + radius, y: maxY))
        p.addArc(
            withCenter: CGPoint(x: minX + radius, y: maxY - radius),
            radius: radius,
            startAngle: .pi * 0.5,
            endAngle: .pi,
            clockwise: true
        )
        p.addLine(to: CGPoint(x: minX, y: maxY - length))

        return p
    }

    private func updateScanLineAnimation() {
        scanLineLayer.removeAllAnimations()
        guard cutoutRect.width > 40 else { return }

        let inset: CGFloat = 18
        let startY = cutoutRect.minY + inset
        let endY = cutoutRect.maxY - inset
        scanLineLayer.frame = CGRect(
            x: cutoutRect.minX + inset,
            y: startY,
            width: cutoutRect.width - inset * 2,
            height: 2.0
        )

        guard !UIAccessibility.isReduceMotionEnabled else {
            scanLineLayer.position.y = cutoutRect.midY
            return
        }

        let sweep = CABasicAnimation(keyPath: "position.y")
        sweep.fromValue = startY
        sweep.toValue = endY
        sweep.duration = 2.1
        sweep.autoreverses = true
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        scanLineLayer.add(sweep, forKey: "marcoQrSweep")
    }
}

// MARK: - Pure UIKit QR Code Camera Scanner

/// Native `AVCaptureSession` + `AVCaptureMetadataOutput` (`.qr`) scanner with sleek translucent reticle,
/// torch toggle, clipboard paste, and automatic manual-entry fallback dialog on Simulator or missing camera.
public final class QrScannerViewController: UIViewController,
    AVCaptureMetadataOutputObjectsDelegate,
    UIAdaptivePresentationControllerDelegate {

    public var onResult: ((String?) -> Void)? {
        didSet {
            completionBox.set(onResult)
        }
    }

    private let completionBox: QrScannerCompletionBox
    private let promptSubtitle: String
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.pilipala.marcomovie.ios.qr-scanner.session")
    private var captureDevice: AVCaptureDevice?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isTorchOn = false
    private var finished = false
    private var cameraConfigured = false

    private let reticleOverlay = QrReticleOverlayView()
    private let statusGlass = MarcoGlassSurfaceView(style: .ultraThin, cornerRadius: 14)
    private let statusLabel = UILabel()
    private let controlsGlass = MarcoGlassSurfaceView(style: .capsule, isInteractive: true)
    private let torchButton = UIButton(type: .system)
    private let pasteButton = UIButton(type: .system)
    private let manualInputButton = UIButton(type: .system)

    public init(
        title: String = "扫描二维码",
        subtitle: String = "对准二维码自动识别，或使用下方粘贴与手动输入",
        onResult: ((String?) -> Void)? = nil
    ) {
        self.promptSubtitle = subtitle
        self.onResult = onResult
        self.completionBox = QrScannerCompletionBox(onResult)
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        completionBox.fireOnce(nil)
    }

    /// Presents the QR scanner adaptively (iPad centered `.formSheet` 540x620, iPhone `.large` sheet).
    public static func present(
        from host: UIViewController,
        title: String = "扫描二维码",
        subtitle: String = "对准二维码自动识别，或使用下方粘贴与手动输入",
        onResult: @escaping (String?) -> Void
    ) {
        let vc = QrScannerViewController(title: title, subtitle: subtitle, onResult: onResult)
        let nav = UINavigationController(rootViewController: vc)
        let options = MarcoModalOptions(
            detents: [.large],
            preferredFormSheetSize: CGSize(width: 540, height: 620),
            prefersGrabberVisible: false,
            preferredCornerRadius: MarcoRadii.sheet,
            wrapInNavigationController: false,
            presentationDelegate: vc
        )
        MarcoModalPresenter.present(nav, from: host, options: options)
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1.0)
        navigationItem.largeTitleDisplayMode = .never
        configureNavigationAppearance()

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "取消",
            style: .plain,
            target: self,
            action: #selector(handleCancel)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "手动输入",
            style: .plain,
            target: self,
            action: #selector(handleManualInput)
        )

        setupOverlayUI()
        configureCameraIfAuthorized()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        updatePreviewOrientation()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setTorch(enabled: false)
        stopCapture()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            finish(with: nil, dismissModal: false)
        }
    }

    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finish(with: nil, dismissModal: false)
    }

    // MARK: - UI Construction

    private func configureNavigationAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.titleTextAttributes = [
            .foregroundColor: UIColor.white,
            .font: MarcoTypography.bodySemibold,
        ]
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationController?.navigationBar.tintColor = .white
    }

    private func setupOverlayUI() {
        reticleOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(reticleOverlay)

        statusGlass.translatesAutoresizingMaskIntoConstraints = false
        statusGlass.overrideUserInterfaceStyle = .dark
        view.addSubview(statusGlass)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = promptSubtitle
        statusLabel.textColor = .white
        statusLabel.font = MarcoTypography.cardSubtitle
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusGlass.contentView.addSubview(statusLabel)

        controlsGlass.translatesAutoresizingMaskIntoConstraints = false
        controlsGlass.overrideUserInterfaceStyle = .dark
        view.addSubview(controlsGlass)

        configureControlButton(
            torchButton,
            title: "手电筒",
            symbol: "flashlight.off.fill",
            action: #selector(handleToggleTorch)
        )
        configureControlButton(
            pasteButton,
            title: "粘贴链接",
            symbol: "doc.on.clipboard",
            action: #selector(handlePaste)
        )
        configureControlButton(
            manualInputButton,
            title: "输入",
            symbol: "keyboard",
            action: #selector(handleManualInput)
        )

        let controlStack = UIStackView(arrangedSubviews: [torchButton, pasteButton, manualInputButton])
        controlStack.translatesAutoresizingMaskIntoConstraints = false
        controlStack.axis = .horizontal
        controlStack.spacing = 6
        controlStack.distribution = .fillEqually
        controlsGlass.contentView.addSubview(controlStack)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            reticleOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            reticleOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            reticleOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            reticleOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            controlsGlass.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controlsGlass.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -24),
            controlsGlass.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 20),
            controlsGlass.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -20),
            controlsGlass.heightAnchor.constraint(equalToConstant: 52),

            controlStack.topAnchor.constraint(equalTo: controlsGlass.contentView.topAnchor, constant: 4),
            controlStack.bottomAnchor.constraint(equalTo: controlsGlass.contentView.bottomAnchor, constant: -4),
            controlStack.leadingAnchor.constraint(equalTo: controlsGlass.contentView.leadingAnchor, constant: 10),
            controlStack.trailingAnchor.constraint(equalTo: controlsGlass.contentView.trailingAnchor, constant: -10),

            statusGlass.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusGlass.bottomAnchor.constraint(equalTo: controlsGlass.topAnchor, constant: -16),
            statusGlass.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 24),
            statusGlass.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -24),

            statusLabel.topAnchor.constraint(equalTo: statusGlass.contentView.topAnchor, constant: 9),
            statusLabel.bottomAnchor.constraint(equalTo: statusGlass.contentView.bottomAnchor, constant: -9),
            statusLabel.leadingAnchor.constraint(equalTo: statusGlass.contentView.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: statusGlass.contentView.trailingAnchor, constant: -14),
        ])
    }

    private func configureControlButton(_ button: UIButton, title: String, symbol: String, action: Selector) {
        let icon = MarcoSymbols.image(symbol, pointSize: 14, weight: .semibold, hierarchicalColor: .white)
        if #available(iOS 15.0, *) {
            var cfg = UIButton.Configuration.plain()
            var attr = AttributedString(title)
            attr.font = MarcoTypography.caption
            cfg.attributedTitle = attr
            cfg.image = icon
            cfg.imagePadding = 5
            cfg.baseForegroundColor = .white
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
            button.configuration = cfg
        } else {
            button.setTitle(title, for: .normal)
            button.setTitleColor(.white, for: .normal)
            button.titleLabel?.font = MarcoTypography.caption
            button.setImage(icon, for: .normal)
            button.tintColor = .white
            button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
            button.imageEdgeInsets = UIEdgeInsets(top: 0, left: -3, bottom: 0, right: 3)
        }
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    // MARK: - Camera Setup & Capture

    private func configureCameraIfAuthorized() {
        #if targetEnvironment(simulator)
        showCameraUnavailableState(message: "模拟器无可用相机，请点击「手动输入」或「粘贴链接」")
        return
        #else
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch authStatus {
        case .authorized:
            startCaptureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if granted {
                        self.startCaptureSession()
                    } else {
                        self.showCameraUnavailableState(message: "未开启相机权限，可粘贴链接或手动输入")
                    }
                }
            }
        default:
            showCameraUnavailableState(message: "未开启相机权限，可粘贴链接或手动输入")
        }
        #endif
    }

    private func showCameraUnavailableState(message: String) {
        statusLabel.text = message
        torchButton.isEnabled = false
        torchButton.alpha = 0.45
    }

    private func startCaptureSession() {
        guard !cameraConfigured else { return }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            showCameraUnavailableState(message: "当前设备相机不可用，可粘贴链接或手动输入")
            return
        }

        cameraConfigured = true
        captureDevice = device
        torchButton.isEnabled = device.hasTorch
        torchButton.alpha = device.hasTorch ? 1.0 : 0.45

        captureSession.beginConfiguration()
        captureSession.addInput(input)
        let output = AVCaptureMetadataOutput()
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }
        }
        captureSession.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: captureSession)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
        updatePreviewOrientation()

        sessionQueue.async { [captureSession] in
            if !captureSession.isRunning {
                captureSession.startRunning()
            }
        }
    }

    private func updatePreviewOrientation() {
        guard let connection = previewLayer?.connection,
              connection.isVideoOrientationSupported else {
            return
        }
        let interfaceOrientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        switch interfaceOrientation {
        case .landscapeLeft:
            connection.videoOrientation = .landscapeLeft
        case .landscapeRight:
            connection.videoOrientation = .landscapeRight
        case .portraitUpsideDown:
            connection.videoOrientation = .portraitUpsideDown
        default:
            connection.videoOrientation = .portrait
        }
    }

    private func stopCapture() {
        let session = captureSession
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func setTorch(enabled: Bool) {
        guard let device = captureDevice, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = enabled ? .on : .off
            device.unlockForConfiguration()
            isTorchOn = enabled
            let symbol = enabled ? "flashlight.on.fill" : "flashlight.off.fill"
            let title = enabled ? "关灯" : "手电筒"
            let icon = MarcoSymbols.image(symbol, pointSize: 14, weight: .semibold, hierarchicalColor: .white)
            if #available(iOS 15.0, *) {
                var cfg = torchButton.configuration ?? UIButton.Configuration.plain()
                var attr = AttributedString(title)
                attr.font = MarcoTypography.caption
                cfg.attributedTitle = attr
                cfg.image = icon
                torchButton.configuration = cfg
            } else {
                torchButton.setTitle(title, for: .normal)
                torchButton.setImage(icon, for: .normal)
            }
        } catch {
            isTorchOn = false
        }
    }

    // MARK: - Actions & Delegate

    public func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !finished,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let raw = obj.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return
        }
        MarcoHaptics.success()
        reticleOverlay.pulseSuccess()
        finish(with: raw, dismissModal: true)
    }

    @objc private func handleCancel() {
        finish(with: nil, dismissModal: true)
    }

    @objc private func handleToggleTorch() {
        MarcoHaptics.light()
        setTorch(enabled: !isTorchOn)
    }

    @objc private func handlePaste() {
        let pasted = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if pasted.isEmpty {
            MarcoHaptics.warning()
            statusLabel.text = "剪贴板暂无可用内容"
            return
        }
        MarcoHaptics.success()
        finish(with: pasted, dismissModal: true)
    }

    @objc private func handleManualInput() {
        MarcoHaptics.selection()
        let alert = UIAlertController(
            title: "手动输入内容",
            message: "可输入二维码链接、订阅地址或绑定口令",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "粘贴或输入内容"
            field.clearButtonMode = .whileEditing
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认", style: .default) { [weak self, weak alert] _ in
            let text = (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            MarcoHaptics.success()
            self?.finish(with: text, dismissModal: true)
        })
        present(alert, animated: true)
    }

    private func finish(with value: String?, dismissModal: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.finish(with: value, dismissModal: dismissModal)
            }
            return
        }
        guard !finished else { return }
        finished = true
        setTorch(enabled: false)
        stopCapture()
        let box = completionBox
        let target = navigationController ?? self
        if dismissModal, target.presentingViewController != nil, !target.isBeingDismissed {
            target.dismiss(animated: true) {
                box.fireOnce(value)
            }
        } else {
            box.fireOnce(value)
        }
    }
}
