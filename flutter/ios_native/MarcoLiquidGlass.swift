// MARK: - iOS 26 Native Liquid Glass Bridge (injected into AppDelegate.swift by prepare_platform.py)

private enum MarcoLiquidGlassSupport {
  static var bridgeChannel: FlutterMethodChannel?
  static var brandLogoImage: UIImage?
  static var interfaceStyle: UIUserInterfaceStyle = .unspecified
  static var glassIntensity: CGFloat = 0.68
  static var isSceneActive: Bool = true
  static let appearanceChangedNotification = Notification.Name("MarcoLiquidGlassAppearanceChanged")
  static let glassIntensityChangedNotification = Notification.Name("MarcoLiquidGlassIntensityChanged")
  static let windowGeometryChangedNotification = Notification.Name("MarcoWindowGeometryChanged")
  static let sceneActivationChangedNotification = Notification.Name("MarcoSceneActivationChanged")
  private static var accessibilityObservers: [NSObjectProtocol] = []
  private static var hiddenAirPlayPicker: AVRoutePickerView?
  private static var activeMenuButtons: Set<ObjectIdentifier> = []

  /// Resolves the active UIWindow across UIScene / iPhone Duo fold-unfold / Split View
  /// without touching the deprecated `UIScreen.main` global.
  static func activeWindow(for view: UIView? = nil) -> UIWindow? {
    if let win = view?.window {
      return win
    }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    if let keyWin = activeScene?.windows.first(where: { $0.isKeyWindow }) {
      return keyWin
    }
    if let anyKey = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) {
      return anyKey
    }
    return activeScene?.windows.first ?? scenes.flatMap({ $0.windows }).first
  }

  static func activeWindowBounds(for view: UIView? = nil) -> CGRect {
    if let win = activeWindow(for: view), win.bounds.width > 0, win.bounds.height > 0 {
      return win.bounds
    }
    if let v = view, v.bounds.width > 0, v.bounds.height > 0 {
      return v.bounds
    }
    return CGRect(x: 0.0, y: 0.0, width: 390.0, height: 844.0)
  }

  static func notifyWindowGeometryChanged(size: CGSize) {
    NotificationCenter.default.post(
      name: windowGeometryChangedNotification,
      object: nil,
      userInfo: ["width": size.width, "height": size.height]
    )
  }

  static var isEffectiveDark: Bool {
    return isEffectiveDark(for: nil)
  }

  static func isEffectiveDark(for view: UIView?) -> Bool {
    switch interfaceStyle {
    case .dark:
      return true
    case .light:
      return false
    default:
      if let v = view, v.traitCollection.userInterfaceStyle != .unspecified {
        return v.traitCollection.userInterfaceStyle != .light
      }
      if let win = activeWindow() {
        return win.traitCollection.userInterfaceStyle != .light
      }
      return UITraitCollection.current.userInterfaceStyle != .light
    }
  }

  static func adaptiveGlassForeground(for view: UIView?, forceDark: Bool = false) -> UIColor {
    let dark = forceDark || isEffectiveDark(for: view)
    return dark ? .white : UIColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 0.94)
  }

  private static func restyleNativeViews(in view: UIView, style: UIUserInterfaceStyle) {
    if view.tag == 99001 {
      // Forced-dark media overlay subtree (Detail / Hero / Player): keep .dark intact.
      return
    }
    if view.overrideUserInterfaceStyle != style {
      view.overrideUserInterfaceStyle = style
    }
    if let seg = view as? UISegmentedControl {
      let dark = isEffectiveDark(for: seg)
      seg.setTitleTextAttributes(
        [
          .foregroundColor: dark ? UIColor.white.withAlphaComponent(0.76) : UIColor.label.withAlphaComponent(0.74),
          .font: UIFont.systemFont(ofSize: 13.0, weight: .semibold),
        ],
        for: .normal
      )
      seg.setTitleTextAttributes(
        [
          .foregroundColor: dark ? UIColor.white : UIColor.label,
          .font: UIFont.systemFont(ofSize: 13.0, weight: .semibold),
        ],
        for: .selected
      )
    }
    for sub in view.subviews {
      restyleNativeViews(in: sub, style: style)
    }
  }

  static func applyWindowAppearance(_ mode: String) {
    let style: UIUserInterfaceStyle
    switch mode.lowercased() {
    case "light":
      style = .light
    case "dark":
      style = .dark
    default:
      style = .unspecified
    }
    interfaceStyle = style
    let winBg: UIColor = isEffectiveDark
      ? UIColor.black
      : UIColor(red: 0.914, green: 0.925, blue: 0.949, alpha: 1.0)
    for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
      for win in scene.windows {
        win.overrideUserInterfaceStyle = style
        win.backgroundColor = winBg
        win.rootViewController?.view.backgroundColor = winBg
        restyleNativeViews(in: win, style: style)
        if let marcoVC = win.rootViewController as? MarcoFlutterViewController {
          marcoVC.marcoPreferredInterfaceStyle = style
        }
      }
    }
    NotificationCenter.default.post(name: appearanceChangedNotification, object: nil)
  }

  static func applyGlassIntensity(_ value: Double) {
    // Native iOS 26 UIGlassEffect manages optical refraction & legibility natively;
    // avoid tinting or adding opaque milky backgrounds over UIGlassEffect views.
    glassIntensity = CGFloat(min(max(value, 0.0), 1.0))
  }

  static func presentNativeAirPlayPicker() {
    guard let host = topPresenter() else { return }
    let picker = hiddenAirPlayPicker ?? AVRoutePickerView(frame: CGRect(x: -100, y: -100, width: 44, height: 44))
    hiddenAirPlayPicker = picker
    picker.prioritizesVideoDevices = true
    picker.isHidden = true
    if picker.superview == nil {
      host.view.addSubview(picker)
    }
    for sub in picker.subviews {
      if let btn = sub as? UIButton {
        btn.sendActions(for: .touchUpInside)
        return
      }
    }
  }

  static func triggerFavoriteDynamicIslandFeedback(phase: String) -> [String: Any] {
    let win = activeWindow()
    let winBounds = activeWindowBounds()
    let topInset = win?.safeAreaInsets.top ?? 0.0
    let screenW = winBounds.width
    let isPhone = UIDevice.current.userInterfaceIdiom == .phone
    // Guard against iPhone Duo unfolded inner display (669pt+) where there is no
    // centered Dynamic Island cutout.
    let hasIsland = isPhone && topInset >= 52.0 && screenW < 520.0
    if phase == "shutter" {
      let medium = UIImpactFeedbackGenerator(style: .medium)
      medium.prepare()
      medium.impactOccurred(intensity: 0.9)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.065) {
        let light = UIImpactFeedbackGenerator(style: .light)
        light.impactOccurred(intensity: 0.65)
      }
    } else if phase == "arrive" {
      let notif = UINotificationFeedbackGenerator()
      notif.prepare()
      notif.notificationOccurred(.success)
    }
    let islandW: CGFloat = 126.0
    let islandH: CGFloat = 37.0
    let islandY: CGFloat = hasIsland ? 11.0 : max(topInset + 6.0, 12.0)
    return [
      "hasDynamicIsland": hasIsland,
      "islandX": Double((screenW - islandW) * 0.5),
      "islandTop": Double(islandY),
      "islandY": Double(islandY),
      "islandWidth": Double(islandW),
      "islandHeight": Double(islandH),
    ]
  }

  static var isAvailable: Bool {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      return true
    }
    #endif
    return false
  }

  static var isReduceTransparencyEnabled: Bool {
    return UIAccessibility.isReduceTransparencyEnabled
  }

  static var majorOSVersion: Int {
    return ProcessInfo.processInfo.operatingSystemVersion.majorVersion
  }

  static var builtWithSDK26: Bool {
    #if compiler(>=6.2)
    return true
    #else
    return false
    #endif
  }

  static func animateSpring(
    duration: TimeInterval = 0.38,
    bounce: CGFloat = 0.16,
    animations: @escaping () -> Void,
    completion: (() -> Void)? = nil
  ) {
    if UIAccessibility.isReduceMotionEnabled {
      UIView.animate(withDuration: 0.14, delay: 0.0, options: [.beginFromCurrentState, .allowUserInteraction], animations: animations) { _ in
        completion?()
      }
      return
    }
    if #available(iOS 17.0, *) {
      let timing = UISpringTimingParameters(duration: duration, bounce: bounce)
      let animator = UIViewPropertyAnimator(duration: 0.0, timingParameters: timing)
      animator.isInterruptible = true
      animator.isUserInteractionEnabled = true
      animator.addAnimations(animations)
      if let completion = completion {
        animator.addCompletion { _ in completion() }
      }
      animator.startAnimation()
    } else {
      let damping = max(0.55, min(0.98, 1.0 - bounce))
      UIView.animate(
        withDuration: duration,
        delay: 0.0,
        usingSpringWithDamping: damping,
        initialSpringVelocity: 0.6,
        options: [.beginFromCurrentState, .allowUserInteraction],
        animations: animations
      ) { _ in
        completion?()
      }
    }
  }

  private static func updateSceneActivationState() {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let active = scenes.isEmpty || scenes.contains { $0.activationState == .foregroundActive }
    if isSceneActive != active {
      isSceneActive = active
      NotificationCenter.default.post(name: sceneActivationChangedNotification, object: nil)
      bridgeChannel?.invokeMethod("sceneActivationChanged", arguments: active)
    }
  }

  private static func installAccessibilityObservers() {
    let center = NotificationCenter.default
    for token in accessibilityObservers {
      center.removeObserver(token)
    }
    accessibilityObservers.removeAll()
    let notify: (Notification) -> Void = { _ in
      DispatchQueue.main.async {
        bridgeChannel?.invokeMethod(
          "reduceTransparencyChanged",
          arguments: isReduceTransparencyEnabled
        )
      }
    }
    accessibilityObservers.append(
      center.addObserver(
        forName: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
        object: nil,
        queue: .main,
        using: notify
      )
    )
    accessibilityObservers.append(
      center.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil,
        queue: .main,
        using: notify
      )
    )
    accessibilityObservers.append(
      center.addObserver(
        forName: UIScene.didActivateNotification,
        object: nil,
        queue: .main
      ) { _ in
        isSceneActive = true
        NotificationCenter.default.post(name: sceneActivationChangedNotification, object: nil)
        bridgeChannel?.invokeMethod("sceneActivationChanged", arguments: true)
      }
    )
    accessibilityObservers.append(
      center.addObserver(
        forName: UIScene.willDeactivateNotification,
        object: nil,
        queue: .main
      ) { _ in
        DispatchQueue.main.async {
          updateSceneActivationState()
        }
      }
    )
  }

  static func showMenuAtRect(args: [String: Any], completion: @escaping FlutterResult) {
    guard let host = topPresenter(),
          let rawItems = args["items"] as? [[String: Any]],
          !rawItems.isEmpty else {
      completion(nil)
      return
    }
    let title = (args["title"] as? String) ?? ""
    let anchor = args["anchorRect"] as? [String: Any]
    let ax = CGFloat((anchor?["x"] as? NSNumber)?.doubleValue ?? Double(host.view.bounds.midX))
    let ay = CGFloat((anchor?["y"] as? NSNumber)?.doubleValue ?? Double(host.view.bounds.midY))
    let aw = max(CGFloat((anchor?["width"] as? NSNumber)?.doubleValue ?? 40.0), 4.0)
    let ah = max(CGFloat((anchor?["height"] as? NSNumber)?.doubleValue ?? 40.0), 4.0)

    if #available(iOS 17.4, *) {
      var resolved = false
      var pendingCompletion: FlutterResult? = completion
      let anchorBtn = MarcoEphemeralMenuAnchorButton(type: .system)
      let btnId = ObjectIdentifier(anchorBtn)
      activeMenuButtons.insert(btnId)

      func finish(_ selectedId: String?) {
        guard !resolved else { return }
        resolved = true
        activeMenuButtons.remove(btnId)
        anchorBtn.removeFromSuperview()
        let cb = pendingCompletion
        pendingCompletion = nil
        cb?(selectedId)
      }

      guard let menu = buildMenu(title: title, rawItems: rawItems, onSelect: { selectedId in
        finish(selectedId)
      }) else {
        finish(nil)
        return
      }

      anchorBtn.frame = CGRect(
        x: max(4.0, min(ax, host.view.bounds.width - aw - 4.0)),
        y: max(4.0, min(ay, host.view.bounds.height - ah - 4.0)),
        width: aw,
        height: ah
      )
      anchorBtn.backgroundColor = .clear
      anchorBtn.alpha = 0.02
      anchorBtn.overrideUserInterfaceStyle = interfaceStyle
      anchorBtn.menu = menu
      anchorBtn.showsMenuAsPrimaryAction = true
      anchorBtn.onMenuEnded = {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
          finish(nil)
        }
      }
      host.view.addSubview(anchorBtn)
      anchorBtn.performPrimaryAction()
      return
    }
    MarcoNativeOptionSheetController.present(args: args, completion: completion)
  }

  static func register(with registrar: FlutterPluginRegistrar, messenger: FlutterBinaryMessenger) {
    brandLogoImage = loadBrandLogoImage(registrar: registrar)

    let channel = FlutterMethodChannel(
      name: "marco_movie/ios_liquid_glass",
      binaryMessenger: messenger
    )
    bridgeChannel = channel
    installAccessibilityObservers()
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "capabilities":
        result([
          "available": isAvailable,
          "majorVersion": majorOSVersion,
          "sdk26": builtWithSDK26,
          "reduceTransparency": isReduceTransparencyEnabled,
          "sceneActive": isSceneActive,
        ])
      case "configureRootTabChrome":
        guard let args = call.arguments as? [String: Any] else {
          result(false)
          return
        }
        DispatchQueue.main.async {
          MarcoIos27RootTabChromeController.shared.configure(args: args)
          result(true)
        }
      case "setRootTabSelectedIndex":
        DispatchQueue.main.async {
          if let dict = call.arguments as? [String: Any], let idx = dict["index"] as? Int {
            let animated = (dict["animated"] as? Bool) ?? true
            MarcoIos27RootTabChromeController.shared.setSelectedIndex(idx, animated: animated)
          } else if let idx = call.arguments as? Int {
            MarcoIos27RootTabChromeController.shared.setSelectedIndex(idx, animated: true)
          }
          result(nil)
        }
      case "setRootTabMinimized":
        DispatchQueue.main.async {
          if let dict = call.arguments as? [String: Any] {
            if let progress = (dict["progress"] as? NSNumber)?.doubleValue {
              MarcoIos27RootTabChromeController.shared.updateScrollMinimizeProgress(CGFloat(progress))
            } else {
              let minimized = (dict["minimized"] as? Bool) ?? false
              let animated = (dict["animated"] as? Bool) ?? true
              MarcoIos27RootTabChromeController.shared.setMinimized(minimized, animated: animated)
            }
          } else if let minimized = call.arguments as? Bool {
            MarcoIos27RootTabChromeController.shared.setMinimized(minimized, animated: true)
          }
          result(nil)
        }
      case "setRootTabVisible":
        DispatchQueue.main.async {
          if let dict = call.arguments as? [String: Any] {
            let visible = (dict["visible"] as? Bool) ?? true
            let animated = (dict["animated"] as? Bool) ?? true
            MarcoIos27RootTabChromeController.shared.setRootDockVisible(visible, animated: animated)
          } else if let visible = call.arguments as? Bool {
            MarcoIos27RootTabChromeController.shared.setRootDockVisible(visible, animated: true)
          }
          result(nil)
        }
      case "showMenuAtRect":
        guard let args = call.arguments as? [String: Any] else {
          result(nil)
          return
        }
        DispatchQueue.main.async {
          showMenuAtRect(args: args, completion: result)
        }
      case "showAlert":
        guard let args = call.arguments as? [String: Any] else {
          result(nil)
          return
        }
        DispatchQueue.main.async {
          MarcoNativeAlertPresenter.presentAlert(args: args, completion: result)
        }
      case "showActionSheet":
        guard let args = call.arguments as? [String: Any] else {
          result(nil)
          return
        }
        DispatchQueue.main.async {
          MarcoNativeAlertPresenter.presentActionSheet(args: args, completion: result)
        }
      case "showOptionSheet":
        guard let args = call.arguments as? [String: Any] else {
          result(nil)
          return
        }
        DispatchQueue.main.async {
          MarcoNativeOptionSheetController.present(args: args, completion: result)
        }
      case "showFilterSheet":
        guard let args = call.arguments as? [String: Any] else {
          result(nil)
          return
        }
        DispatchQueue.main.async {
          MarcoNativeFilterSheetController.present(args: args, completion: result)
        }
      case "showPrivacyPin":
        guard let args = call.arguments as? [String: Any] else {
          result(nil)
          return
        }
        DispatchQueue.main.async {
          MarcoNativePinSheetController.present(args: args, completion: result)
        }
      case "dismissActiveSheets":
        DispatchQueue.main.async {
          MarcoNativeSheetCoordinator.dismissAllActive()
          result(nil)
        }
      case "setAppearanceMode":
        let mode = (call.arguments as? String) ?? "system"
        DispatchQueue.main.async {
          applyWindowAppearance(mode)
          result(nil)
        }
      case "setGlassIntensity":
        let val = (call.arguments as? NSNumber)?.doubleValue ?? 0.68
        DispatchQueue.main.async {
          applyGlassIntensity(val)
          result(nil)
        }
      case "presentAirPlayPicker":
        DispatchQueue.main.async {
          presentNativeAirPlayPicker()
          result(true)
        }
      case "triggerFavoriteDynamicIslandFeedback":
        let phase = (call.arguments as? String) ?? "shutter"
        DispatchQueue.main.async {
          result(triggerFavoriteDynamicIslandFeedback(phase: phase))
        }
      case "discoverBonjourDevices":
        let args = (call.arguments as? [String: Any]) ?? [:]
        let types = (args["serviceTypes"] as? [String]) ?? [
          "_marcomovie-cast._tcp.",
          "_airplay._tcp.",
          "_raop._tcp.",
          "_lelink._tcp.",
          "_lebo._tcp.",
          "_googlecast._tcp.",
          "_dlna._tcp.",
          "_upnp._tcp.",
        ]
        let timeoutMs = (args["timeoutMs"] as? NSNumber)?.intValue ?? 2200
        DispatchQueue.main.async {
          MarcoBonjourScanner.scan(serviceTypes: types, timeoutMs: timeoutMs) { payload in
            result(payload)
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    registrar.register(
      MarcoNativeDockFactory(messenger: messenger),
      withId: "marco_movie/ios26_dock"
    )
    registrar.register(
      MarcoNativeGlassButtonFactory(messenger: messenger),
      withId: "marco_movie/ios26_glass_button"
    )
    registrar.register(
      MarcoNativeGlassPillFactory(messenger: messenger),
      withId: "marco_movie/ios26_glass_pill"
    )
    registrar.register(
      MarcoNativeSegmentedControlFactory(messenger: messenger),
      withId: "marco_movie/ios26_segmented_control"
    )
    registrar.register(
      MarcoNativeSwitchFactory(messenger: messenger),
      withId: "marco_movie/ios26_switch"
    )
    registrar.register(
      MarcoNativeSliderFactory(messenger: messenger),
      withId: "marco_movie/ios26_slider"
    )
  }

  private static func loadBrandLogoImage(registrar: FlutterPluginRegistrar) -> UIImage? {
    let key = registrar.lookupKey(forAsset: "assets/logo_mark.png")
    let path = Bundle.main.path(forResource: key, ofType: nil)
      ?? Bundle.main.path(forResource: FlutterDartProject.lookupKey(forAsset: "assets/logo_mark.png"), ofType: nil)
    if let filePath = path, let raw = UIImage(contentsOfFile: filePath) {
      let target = CGSize(width: 32.0, height: 32.0)
      let scale = min(target.width / max(raw.size.width, 1.0), target.height / max(raw.size.height, 1.0))
      let drawSize = CGSize(width: raw.size.width * scale, height: raw.size.height * scale)
      let drawOrigin = CGPoint(
        x: (target.width - drawSize.width) * 0.5,
        y: (target.height - drawSize.height) * 0.5
      )
      let renderer = UIGraphicsImageRenderer(size: target)
      let rendered = renderer.image { _ in
        raw.draw(in: CGRect(origin: drawOrigin, size: drawSize))
      }
      return rendered.withRenderingMode(.alwaysOriginal)
    }
    let symCfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
    return UIImage(systemName: "film.stack.fill", withConfiguration: symCfg)
  }

  static func colorFromARGB(_ value: Any?) -> UIColor? {
    guard let num = value as? NSNumber else { return nil }
    let argb = num.uint64Value
    let a = CGFloat((argb >> 24) & 0xFF) / 255.0
    let r = CGFloat((argb >> 16) & 0xFF) / 255.0
    let g = CGFloat((argb >> 8) & 0xFF) / 255.0
    let b = CGFloat(argb & 0xFF) / 255.0
    return UIColor(red: r, green: g, blue: b, alpha: a)
  }

  static func isNearWhite(_ color: UIColor) -> Bool {
    var r: CGFloat = 1
    var g: CGFloat = 1
    var b: CGFloat = 1
    var a: CGFloat = 1
    if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
      return r > 0.90 && g > 0.90 && b > 0.90
    }
    return true
  }

  static func isNearBlack(_ color: UIColor) -> Bool {
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 1
    if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
      return r < 0.22 && g < 0.22 && b < 0.22
    }
    return false
  }

  static func withoutAnimations(_ block: () -> Void) {
    UIView.performWithoutAnimation {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      block()
      CATransaction.commit()
    }
  }

  static func resolvedInitialFrame(
    _ frame: CGRect,
    args: [String: Any]?,
    defaultWidth: CGFloat,
    defaultHeight: CGFloat
  ) -> CGRect {
    if frame.width >= 1.0 && frame.height >= 1.0 {
      return frame
    }
    let w = CGFloat((args?["initialWidth"] as? NSNumber)?.doubleValue ?? Double(defaultWidth))
    let h = CGFloat((args?["initialHeight"] as? NSNumber)?.doubleValue ?? Double(defaultHeight))
    return CGRect(x: frame.origin.x, y: frame.origin.y, width: max(w, 1.0), height: max(h, 1.0))
  }

  static func buildMenu(
    title: String = "",
    rawItems: [[String: Any]],
    onSelect: @escaping (String) -> Void
  ) -> UIMenu? {
    guard !rawItems.isEmpty else { return nil }
    var sections: [(title: String, elements: [UIMenuElement])] = []
    var currentSectionKey: Int?
    var currentSectionTitle: String = ""
    var currentBucket: [UIMenuElement] = []

    for item in rawItems {
      let id = (item["id"] as? String) ?? ""
      let label = (item["title"] as? String) ?? ""
      let subtitle = item["subtitle"] as? String
      let symbol = item["symbol"] as? String
      let checked = (item["checked"] as? Bool) ?? false
      let destructive = (item["destructive"] as? Bool) ?? false
      let sectionKey = (item["section"] as? NSNumber)?.intValue ?? 0
      let secTitle = (item["sectionTitle"] as? String) ?? ""

      if let prev = currentSectionKey, prev != sectionKey, !currentBucket.isEmpty {
        sections.append((title: currentSectionTitle, elements: currentBucket))
        currentBucket = []
        currentSectionTitle = ""
      }
      currentSectionKey = sectionKey
      if currentSectionTitle.isEmpty && !secTitle.isEmpty {
        currentSectionTitle = secTitle
      }

      let image = symbol.flatMap { UIImage(systemName: $0) }
      let attrs: UIMenuElement.Attributes = destructive ? [.destructive] : []
      let action = UIAction(
        title: label,
        subtitle: (subtitle?.isEmpty ?? true) ? nil : subtitle,
        image: image,
        attributes: attrs,
        state: checked ? .on : .off
      ) { _ in
        onSelect(id)
      }
      currentBucket.append(action)
    }
    if !currentBucket.isEmpty {
      sections.append((title: currentSectionTitle, elements: currentBucket))
    }
    if sections.count <= 1 && (sections.first?.title.isEmpty ?? true) {
      return UIMenu(title: title, children: sections.first?.elements ?? [])
    }
    let inlineMenus = sections.map { UIMenu(title: $0.title, options: .displayInline, children: $0.elements) }
    return UIMenu(title: title, children: inlineMenus)
  }

  static func topPresenter() -> UIViewController? {
    var presenter = activeWindow()?.rootViewController
    while let presented = presenter?.presentedViewController, !presented.isBeingDismissed {
      presenter = presented
    }
    return presenter
  }
}

private final class MarcoEphemeralMenuAnchorButton: UIButton {
  var onMenuEnded: (() -> Void)?

  override func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willEndFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
    if let animator = animator {
      animator.addCompletion { [weak self] in
        self?.onMenuEnded?()
      }
    } else {
      onMenuEnded?()
    }
  }
}

// MARK: - Single-Flight Native Sheet Coordinator & Deinit Sentinel

private final class _MarcoDeinitKeyToken: Sendable {}

private final class MarcoDeinitSentinel: NSObject {
  private static let keyToken = _MarcoDeinitKeyToken()
  private var onDeinit: (() -> Void)?

  init(onDeinit: @escaping () -> Void) {
    self.onDeinit = onDeinit
    super.init()
  }

  static func attach(to owner: AnyObject, onDeinit: @escaping () -> Void) -> MarcoDeinitSentinel {
    let sentinel = MarcoDeinitSentinel(onDeinit: onDeinit)
    let key = UnsafeRawPointer(Unmanaged.passUnretained(keyToken).toOpaque())
    objc_setAssociatedObject(owner, key, sentinel, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return sentinel
  }

  func invalidate() {
    onDeinit = nil
  }

  deinit {
    let cb = onDeinit
    onDeinit = nil
    if let cb = cb {
      if Thread.isMainThread {
        cb()
      } else {
        DispatchQueue.main.async { cb() }
      }
    }
  }
}

private enum MarcoNativeSheetCoordinator {
  private static var isPresenting = false
  private static weak var activeController: UIViewController?
  private static var activeControllerId: ObjectIdentifier?
  private static var activeCancelHandler: (() -> Void)?

  static func tryBeginPresentation(
    host: UIViewController,
    controller: UIViewController,
    onCancel: @escaping () -> Void
  ) -> Bool {
    // Reclaim stale slot if a previously presented controller disappeared without firing its delegate.
    if let staleId = activeControllerId, !isPresenting {
      let staleGone = activeController == nil || activeController?.presentingViewController == nil
      if staleGone {
        let staleCancel = activeCancelHandler
        activeController = nil
        activeControllerId = nil
        activeCancelHandler = nil
        staleCancel?()
        _ = staleId
      }
    }
    if isPresenting || activeControllerId != nil {
      return false
    }
    if host.isBeingDismissed || host.isBeingPresented {
      return false
    }
    if let existing = host.presentedViewController, !existing.isBeingDismissed {
      return false
    }
    isPresenting = true
    activeController = controller
    activeControllerId = ObjectIdentifier(controller)
    activeCancelHandler = onCancel
    return true
  }

  static func isCurrent(identity: ObjectIdentifier) -> Bool {
    return activeControllerId == identity
  }

  static func didCompletePresentation(identity: ObjectIdentifier) {
    guard activeControllerId == identity else { return }
    isPresenting = false
    if activeController == nil || activeController?.presentingViewController == nil {
      let cancel = activeCancelHandler
      activeController = nil
      activeControllerId = nil
      activeCancelHandler = nil
      cancel?()
    }
  }

  static func didFinish(identity: ObjectIdentifier) {
    guard activeControllerId == identity else { return }
    isPresenting = false
    activeController = nil
    activeControllerId = nil
    activeCancelHandler = nil
  }

  static func dismissAllActive() {
    let vc = activeController
    let cancel = activeCancelHandler
    isPresenting = false
    activeController = nil
    activeControllerId = nil
    activeCancelHandler = nil
    if let presented = vc, presented.isBeingPresented,
       let coordinator = presented.transitionCoordinator {
      cancel?()
      coordinator.animate(alongsideTransition: nil) { _ in
        if presented.presentingViewController != nil && !presented.isBeingDismissed {
          presented.dismiss(animated: false, completion: nil)
        }
      }
    } else if let presented = vc, presented.presentingViewController != nil, !presented.isBeingDismissed {
      presented.dismiss(animated: false) {
        cancel?()
      }
    } else {
      cancel?()
    }
  }

  static func presentRespectingDismissTransition(
    host: UIViewController,
    controller: UIViewController,
    identity: ObjectIdentifier,
    onRejected: @escaping () -> Void
  ) {
    let performPresent: () -> Void = {
      guard isCurrent(identity: identity),
            host.presentedViewController == nil,
            !host.isBeingDismissed else {
        onRejected()
        return
      }
      host.present(controller, animated: true) {
        didCompletePresentation(identity: identity)
      }
    }
    if let existing = host.presentedViewController, existing.isBeingDismissed,
       let coordinator = existing.transitionCoordinator {
      coordinator.animate(alongsideTransition: nil) { _ in
        performPresent()
      }
    } else {
      performPresent()
    }
  }
}

// MARK: - Native UIAlertController Presenter (Alert & ActionSheet)

private final class MarcoPopoverDismissBox: NSObject, UIPopoverPresentationControllerDelegate {
  private var onDismiss: (() -> Void)?

  init(onDismiss: @escaping () -> Void) {
    self.onDismiss = onDismiss
    super.init()
  }

  func invalidate() {
    onDismiss = nil
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    let cb = onDismiss
    onDismiss = nil
    cb?()
  }
}

private enum MarcoNativeAlertPresenter {
  private static var activePopoverBoxes: [ObjectIdentifier: MarcoPopoverDismissBox] = [:]

  static func presentAlert(args: [String: Any], completion: @escaping FlutterResult) {
    guard let host = MarcoLiquidGlassSupport.topPresenter() else {
      completion(nil)
      return
    }
    let title = args["title"] as? String
    let message = args["message"] as? String
    let actionDicts = (args["actions"] as? [[String: Any]]) ?? []
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    let alertKey = ObjectIdentifier(alert)

    var resolved = false
    var pendingCompletion: FlutterResult? = completion
    weak var weakSentinel: MarcoDeinitSentinel?
    func finish(_ value: Any?) {
      guard !resolved else { return }
      resolved = true
      weakSentinel?.invalidate()
      MarcoNativeSheetCoordinator.didFinish(identity: alertKey)
      let cb = pendingCompletion
      pendingCompletion = nil
      cb?(value)
    }

    guard MarcoNativeSheetCoordinator.tryBeginPresentation(
      host: host,
      controller: alert,
      onCancel: { finish(nil) }
    ) else {
      finish(nil)
      return
    }
    weakSentinel = MarcoDeinitSentinel.attach(to: alert) {
      finish(nil)
    }

    if actionDicts.isEmpty {
      alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in finish("ok") })
    } else {
      for dict in actionDicts {
        let id = (dict["id"] as? String) ?? ""
        let label = (dict["title"] as? String) ?? ""
        let styleStr = (dict["style"] as? String) ?? "default"
        let isDefault = (dict["isDefault"] as? Bool) ?? false
        let style: UIAlertAction.Style
        switch styleStr {
        case "cancel":
          style = .cancel
        case "destructive":
          style = .destructive
        default:
          style = .default
        }
        let action = UIAlertAction(title: label, style: style) { _ in
          finish(id)
        }
        alert.addAction(action)
        if isDefault && style != .cancel {
          alert.preferredAction = action
        }
      }
    }

    MarcoNativeSheetCoordinator.presentRespectingDismissTransition(
      host: host,
      controller: alert,
      identity: alertKey,
      onRejected: { finish(nil) }
    )
  }

  static func presentActionSheet(args: [String: Any], completion: @escaping FlutterResult) {
    guard let host = MarcoLiquidGlassSupport.topPresenter() else {
      completion(nil)
      return
    }
    let title = args["title"] as? String
    let message = args["message"] as? String
    let cancelTitle = args["cancelTitle"] as? String
    let actionDicts = (args["actions"] as? [[String: Any]]) ?? []
    let sheet = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
    sheet.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    let sheetKey = ObjectIdentifier(sheet)

    var resolved = false
    var pendingCompletion: FlutterResult? = completion
    weak var weakSentinel: MarcoDeinitSentinel?
    func finish(_ value: Any?) {
      guard !resolved else { return }
      resolved = true
      weakSentinel?.invalidate()
      if let box = activePopoverBoxes.removeValue(forKey: sheetKey) {
        box.invalidate()
      }
      MarcoNativeSheetCoordinator.didFinish(identity: sheetKey)
      let cb = pendingCompletion
      pendingCompletion = nil
      cb?(value)
    }

    guard MarcoNativeSheetCoordinator.tryBeginPresentation(
      host: host,
      controller: sheet,
      onCancel: { finish(nil) }
    ) else {
      finish(nil)
      return
    }
    weakSentinel = MarcoDeinitSentinel.attach(to: sheet) {
      finish(nil)
    }

    for dict in actionDicts {
      let id = (dict["id"] as? String) ?? ""
      let label = (dict["title"] as? String) ?? ""
      let styleStr = (dict["style"] as? String) ?? "default"
      let style: UIAlertAction.Style = (styleStr == "destructive") ? .destructive : .default
      let action = UIAlertAction(title: label, style: style) { _ in
        finish(id)
      }
      sheet.addAction(action)
    }

    if let cancelLabel = cancelTitle, !cancelLabel.isEmpty {
      sheet.addAction(UIAlertAction(title: cancelLabel, style: .cancel) { _ in
        finish(nil)
      })
    }

    if let popover = sheet.popoverPresentationController {
      popover.sourceView = host.view
      popover.sourceRect = CGRect(
        x: host.view.bounds.midX,
        y: max(host.view.bounds.maxY - 96.0, host.view.bounds.midY),
        width: 1,
        height: 1
      )
      popover.permittedArrowDirections = []
      let dismissBox = MarcoPopoverDismissBox {
        finish(nil)
      }
      activePopoverBoxes[sheetKey] = dismissBox
      popover.delegate = dismissBox
    }

    MarcoNativeSheetCoordinator.presentRespectingDismissTransition(
      host: host,
      controller: sheet,
      identity: sheetKey,
      onRejected: { finish(nil) }
    )
  }
}

// MARK: - Native iOS 26 Liquid Glass Half-Sheet Option Picker (UISheetPresentationController)

private final class MarcoNativeOptionSheetController: UIViewController,
  UITableViewDataSource,
  UITableViewDelegate,
  UIAdaptivePresentationControllerDelegate,
  UIPopoverPresentationControllerDelegate
{
  private struct OptionItem {
    let id: String
    let title: String
    let subtitle: String?
    let symbol: String?
    let checked: Bool
    let destructive: Bool
  }

  private struct OptionSection {
    let title: String
    let items: [OptionItem]
  }

  private let sheetTitle: String
  private let sheetSubtitle: String?
  private let cancelTitle: String
  private let forceOpaque: Bool
  private let isPopoverPresentation: Bool
  private let forceDarkSurface: Bool
  private let sections: [OptionSection]
  private let tableView = UITableView(frame: .zero, style: .insetGrouped)

  private var completion: FlutterResult?
  private var resolved = false
  private var dismissing = false
  private var navIdentity: ObjectIdentifier?

  private var isOpaqueMode: Bool {
    return forceOpaque || UIAccessibility.isReduceTransparencyEnabled
  }

  private var useDarkColors: Bool {
    return forceDarkSurface || MarcoLiquidGlassSupport.isEffectiveDark(for: isViewLoaded ? view : nil)
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      let dark = useDarkColors
      tableView.separatorColor = dark
        ? UIColor.white.withAlphaComponent(0.12)
        : UIColor.black.withAlphaComponent(0.10)
      tableView.reloadData()
    }
  }

  override func viewWillTransition(
    to size: CGSize,
    with coordinator: UIViewControllerTransitionCoordinator
  ) {
    super.viewWillTransition(to: size, with: coordinator)
    coordinator.animate(alongsideTransition: { [weak self] _ in
      guard let self = self else { return }
      if self.isPopoverPresentation, let nav = self.navigationController {
        let maxW = min(Double(size.width) - 24.0, 278.0)
        let maxH = min(Double(size.height) * 0.72, 340.0)
        nav.preferredContentSize = CGSize(
          width: max(220.0, min(Double(nav.preferredContentSize.width), maxW)),
          height: min(Double(nav.preferredContentSize.height), max(maxH, 160.0))
        )
      }
      self.view.setNeedsLayout()
      self.view.layoutIfNeeded()
    }, completion: nil)
  }

  func adaptivePresentationStyle(
    for controller: UIPresentationController,
    traitCollection: UITraitCollection
  ) -> UIModalPresentationStyle {
    return isPopoverPresentation ? .none : .automatic
  }

  static func present(args: [String: Any], completion: @escaping FlutterResult) {
    guard let host = MarcoLiquidGlassSupport.topPresenter() else {
      completion(nil)
      return
    }
    let anchorDict = args["anchorRect"] as? [String: Any]
    let vc = MarcoNativeOptionSheetController(
      args: args,
      isPopover: anchorDict != nil,
      completion: completion
    )
    let nav = UINavigationController(rootViewController: vc)
    let navId = ObjectIdentifier(nav)
    vc.navIdentity = navId
    let style: UIUserInterfaceStyle = vc.forceDarkSurface ? .dark : MarcoLiquidGlassSupport.interfaceStyle
    nav.overrideUserInterfaceStyle = style

    if let anchor = anchorDict,
       let ax = (anchor["x"] as? NSNumber)?.doubleValue,
       let ay = (anchor["y"] as? NSNumber)?.doubleValue,
       let aw = (anchor["width"] as? NSNumber)?.doubleValue,
       let ah = (anchor["height"] as? NSNumber)?.doubleValue {
      nav.modalPresentationStyle = .popover
      let itemCount = vc.sections.reduce(0) { $0 + $1.items.count }
      let sectionHeaderCount = vc.sections.filter { !$0.title.isEmpty }.count
      let subtitleRows = vc.sections.flatMap { $0.items }.filter { $0.subtitle != nil }.count
      let rawHeight = 52.0 + Double(itemCount) * 44.0 + Double(subtitleRows) * 14.0 + Double(sectionHeaderCount) * 28.0 + 16.0
      let maxH = min(Double(host.view.bounds.height) * 0.72, 340.0)
      let maxW = min(Double(host.view.bounds.width) - 24.0, 278.0)
      nav.preferredContentSize = CGSize(
        width: max(226.0, maxW),
        height: min(max(rawHeight, 132.0), max(maxH, 160.0))
      )
      if let popover = nav.popoverPresentationController {
        popover.delegate = vc
        popover.sourceView = host.view
        popover.sourceRect = CGRect(
          x: max(4.0, min(CGFloat(ax), host.view.bounds.width - 8.0)),
          y: max(4.0, min(CGFloat(ay), host.view.bounds.height - 8.0)),
          width: max(CGFloat(aw), 1.0),
          height: max(CGFloat(ah), 1.0)
        )
        popover.permittedArrowDirections = [.up, .down, .left, .right]
        popover.canOverlapSourceViewRect = false
      }
    } else {
      nav.modalPresentationStyle = .pageSheet
      nav.presentationController?.delegate = vc
      if let sheet = nav.sheetPresentationController {
        sheet.detents = [.medium(), .large()]
        sheet.prefersGrabberVisible = true
        sheet.preferredCornerRadius = 32.0
        sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        sheet.prefersEdgeAttachedInCompactHeight = true
        sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
      }
    }
    guard MarcoNativeSheetCoordinator.tryBeginPresentation(
      host: host,
      controller: nav,
      onCancel: { [weak vc] in vc?.finish(selectedId: nil) }
    ) else {
      vc.finish(selectedId: nil)
      return
    }
    MarcoNativeSheetCoordinator.presentRespectingDismissTransition(
      host: host,
      controller: nav,
      identity: navId,
      onRejected: { [weak vc] in vc?.finish(selectedId: nil) }
    )
  }

  init(args: [String: Any], isPopover: Bool = false, completion: @escaping FlutterResult) {
    self.sheetTitle = (args["title"] as? String) ?? ""
    let rawSubtitle = (args["subtitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.sheetSubtitle = (rawSubtitle?.isEmpty ?? true) ? nil : rawSubtitle
    self.cancelTitle = (args["cancelTitle"] as? String) ?? "关闭"
    self.forceOpaque = (args["forceOpaque"] as? Bool) ?? false
    self.isPopoverPresentation = isPopover
    self.forceDarkSurface = (args["forceDark"] as? Bool) ?? isPopover
    let rawItems = (args["items"] as? [[String: Any]]) ?? []
    var builtSections: [OptionSection] = []
    var currentKey: Int?
    var currentTitle = ""
    var bucket: [OptionItem] = []

    for raw in rawItems {
      let id = (raw["id"] as? String) ?? ""
      let title = (raw["title"] as? String) ?? ""
      let sub = (raw["subtitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      let sym = (raw["symbol"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      let checked = (raw["checked"] as? Bool) ?? false
      let destructive = (raw["destructive"] as? Bool) ?? false
      let secKey = (raw["section"] as? NSNumber)?.intValue ?? 0
      let secTitle = (raw["sectionTitle"] as? String) ?? ""

      if let prev = currentKey, prev != secKey, !bucket.isEmpty {
        builtSections.append(OptionSection(title: currentTitle, items: bucket))
        bucket = []
        currentTitle = ""
      }
      currentKey = secKey
      if currentTitle.isEmpty && !secTitle.isEmpty {
        currentTitle = secTitle
      }
      bucket.append(
        OptionItem(
          id: id,
          title: title,
          subtitle: (sub?.isEmpty ?? true) ? nil : sub,
          symbol: (sym?.isEmpty ?? true) ? nil : sym,
          checked: checked,
          destructive: destructive
        )
      )
    }
    if !bucket.isEmpty {
      builtSections.append(OptionSection(title: currentTitle, items: bucket))
    }
    self.sections = builtSections
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    guard !resolved else { return }
    resolved = true
    let cb = completion
    completion = nil
    let id = navIdentity
    if Thread.isMainThread {
      if let id = id { MarcoNativeSheetCoordinator.didFinish(identity: id) }
      cb?(nil)
    } else {
      DispatchQueue.main.async {
        if let id = id { MarcoNativeSheetCoordinator.didFinish(identity: id) }
        cb?(nil)
      }
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    let dark = useDarkColors
    overrideUserInterfaceStyle = forceDarkSurface ? .dark : MarcoLiquidGlassSupport.interfaceStyle
    let opaqueFallback = dark
      ? UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
      : UIColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1.0)
    #if compiler(>=6.2)
    if #available(iOS 26.0, *), !isOpaqueMode {
      view.backgroundColor = .clear
    } else {
      view.backgroundColor = opaqueFallback
    }
    #else
    view.backgroundColor = isPopoverPresentation && !isOpaqueMode
      ? (dark ? UIColor(white: 0.12, alpha: 0.88) : UIColor(white: 0.98, alpha: 0.92))
      : opaqueFallback
    #endif

    navigationItem.title = sheetTitle
    if !isPopoverPresentation, let subtitle = sheetSubtitle {
      navigationItem.prompt = subtitle
    }
    if !isPopoverPresentation {
      navigationItem.rightBarButtonItem = UIBarButtonItem(
        title: cancelTitle,
        style: .done,
        target: self,
        action: #selector(closeTapped)
      )
    }

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.overrideUserInterfaceStyle = overrideUserInterfaceStyle
    tableView.backgroundColor = .clear
    tableView.separatorColor = dark
      ? UIColor.white.withAlphaComponent(0.12)
      : UIColor.black.withAlphaComponent(0.10)
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      tableView.cornerConfiguration = .corners(radius: .containerConcentric(minimum: 20.0))
    }
    #endif
    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "MarcoOptionCell")
    view.addSubview(tableView)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleSceneActivationChanged),
      name: MarcoLiquidGlassSupport.sceneActivationChangedNotification,
      object: nil
    )

    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
  }

  @objc private func handleSceneActivationChanged() {
    let active = MarcoLiquidGlassSupport.isSceneActive
    UIView.animate(withDuration: 0.18) {
      self.view.alpha = active ? 1.0 : 0.90
    }
  }

  func numberOfSections(in tableView: UITableView) -> Int {
    return sections.count
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    return sections[section].items.count
  }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    let title = sections[section].title
    return title.isEmpty ? nil : title
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "MarcoOptionCell", for: indexPath)
    let item = sections[indexPath.section].items[indexPath.row]
    let dark = useDarkColors
    var cfg = cell.defaultContentConfiguration()
    cfg.text = item.title
    cfg.textProperties.color = item.destructive
      ? UIColor.systemRed
      : (dark ? UIColor.white : UIColor.label)
    cfg.textProperties.font = UIFont.systemFont(
      ofSize: isPopoverPresentation ? 14.5 : 15.0,
      weight: item.checked ? .semibold : .regular
    )
    if let sub = item.subtitle {
      cfg.secondaryText = sub
      cfg.secondaryTextProperties.color = dark
        ? UIColor.white.withAlphaComponent(0.66)
        : UIColor.secondaryLabel
      cfg.secondaryTextProperties.font = UIFont.systemFont(ofSize: 12.0, weight: .regular)
    }
    if let symbol = item.symbol {
      let symCfg = UIImage.SymbolConfiguration(pointSize: 15.5, weight: .medium)
      cfg.image = UIImage(systemName: symbol, withConfiguration: symCfg)
      cfg.imageProperties.tintColor = item.destructive
        ? UIColor.systemRed
        : (item.checked
            ? UIColor.systemBlue
            : (dark ? UIColor.white.withAlphaComponent(0.84) : UIColor.label))
    }
    cell.contentConfiguration = cfg
    cell.accessoryType = item.checked ? .checkmark : .none
    cell.tintColor = UIColor.systemBlue
    let alpha: CGFloat = isOpaqueMode ? 0.96 : (isPopoverPresentation ? 0.42 : 0.72)
    cell.backgroundColor = dark
      ? UIColor(white: 0.16, alpha: alpha)
      : UIColor(white: 1.0, alpha: isOpaqueMode ? 0.98 : 0.78)
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard !resolved, !dismissing else { return }
    dismissing = true
    let item = sections[indexPath.section].items[indexPath.row]
    UISelectionFeedbackGenerator().selectionChanged()
    if presentingViewController != nil {
      dismiss(animated: true) {
        self.finish(selectedId: item.id)
      }
    } else {
      finish(selectedId: item.id)
    }
  }

  @objc private func closeTapped() {
    guard !resolved, !dismissing else { return }
    dismissing = true
    if presentingViewController != nil {
      dismiss(animated: true) {
        self.finish(selectedId: nil)
      }
    } else {
      finish(selectedId: nil)
    }
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    finish(selectedId: nil)
  }

  private func finish(selectedId: String?) {
    guard !resolved else { return }
    resolved = true
    if let id = navIdentity {
      MarcoNativeSheetCoordinator.didFinish(identity: id)
    }
    let cb = completion
    completion = nil
    cb?(selectedId)
  }
}

// MARK: - Native iOS 26 Liquid Glass Filter Sheet (UISheetPresentationController)

private final class MarcoWrapChipContainerView: UIView {
  var horizontalSpacing: CGFloat = 8.0
  var verticalSpacing: CGFloat = 8.0
  private var chipButtons: [UIButton] = []
  private var lastMeasuredWidth: CGFloat = 0.0
  private var calculatedHeight: CGFloat = 0.0

  func setButtons(_ buttons: [UIButton]) {
    for old in chipButtons {
      old.removeFromSuperview()
    }
    chipButtons = buttons
    for btn in buttons {
      addSubview(btn)
    }
    lastMeasuredWidth = 0.0
    setNeedsLayout()
    invalidateIntrinsicContentSize()
  }

  override var intrinsicContentSize: CGSize {
    return CGSize(width: UIView.noIntrinsicMetric, height: max(calculatedHeight, 34.0))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let maxW = bounds.width
    guard maxW > 0 else { return }
    var x: CGFloat = 0.0
    var y: CGFloat = 0.0
    var rowH: CGFloat = 0.0

    for btn in chipButtons {
      let fit = btn.sizeThatFits(CGSize(width: maxW, height: 36.0))
      let w = min(max(fit.width, 52.0), maxW)
      let h = max(fit.height, 34.0)
      if x > 0 && x + w > maxW {
        x = 0.0
        y += rowH + verticalSpacing
        rowH = 0.0
      }
      btn.frame = CGRect(x: x, y: y, width: w, height: h)
      x += w + horizontalSpacing
      rowH = max(rowH, h)
    }

    let totalH = chipButtons.isEmpty ? 0.0 : (y + rowH)
    if abs(totalH - calculatedHeight) > 0.5 || abs(maxW - lastMeasuredWidth) > 0.5 {
      calculatedHeight = totalH
      lastMeasuredWidth = maxW
      invalidateIntrinsicContentSize()
    }
  }
}

private final class MarcoNativeFilterSheetController: UIViewController, UIAdaptivePresentationControllerDelegate {
  private struct CategoryChoice {
    let id: String
    let label: String
    let kind: String // "all" | "cat" | "genre"
  }

  private let sheetTitle: String
  private let categories: [CategoryChoice]
  private let areas: [String]
  private let years: [String]

  private var selectedCategoryId: String
  private var selectedGenreLabel: String
  private var selectedArea: String
  private var selectedYear: String

  private var categoryButtons: [UIButton] = []
  private var areaButtons: [UIButton] = []
  private var yearButtons: [UIButton] = []

  private let scrollView = UIScrollView()
  private let stackView = UIStackView()

  private var completion: FlutterResult?
  private var resolved = false
  private var navIdentity: ObjectIdentifier?

  static func present(args: [String: Any], completion: @escaping FlutterResult) {
    guard let host = MarcoLiquidGlassSupport.topPresenter() else {
      completion(nil)
      return
    }
    let vc = MarcoNativeFilterSheetController(args: args, completion: completion)
    let nav = UINavigationController(rootViewController: vc)
    let navId = ObjectIdentifier(nav)
    vc.navIdentity = navId
    nav.modalPresentationStyle = .pageSheet
    nav.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    nav.presentationController?.delegate = vc
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 32.0
      sheet.prefersScrollingExpandsWhenScrolledToEdge = true
      sheet.prefersEdgeAttachedInCompactHeight = true
      sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
    }
    guard MarcoNativeSheetCoordinator.tryBeginPresentation(
      host: host,
      controller: nav,
      onCancel: { [weak vc] in vc?.finish(applied: false) }
    ) else {
      vc.finish(applied: false)
      return
    }
    MarcoNativeSheetCoordinator.presentRespectingDismissTransition(
      host: host,
      controller: nav,
      identity: navId,
      onRejected: { [weak vc] in vc?.finish(applied: false) }
    )
  }

  init(args: [String: Any], completion: @escaping FlutterResult) {
    self.sheetTitle = (args["title"] as? String) ?? "多维片库筛选"
    let rawCats = (args["categories"] as? [[String: Any]]) ?? []
    self.categories = rawCats.map {
      CategoryChoice(
        id: ($0["id"] as? String) ?? "",
        label: ($0["label"] as? String) ?? "",
        kind: ($0["kind"] as? String) ?? "all"
      )
    }
    self.areas = (args["areas"] as? [String]) ?? []
    self.years = (args["years"] as? [String]) ?? []
    self.selectedCategoryId = (args["selectedCategoryId"] as? String) ?? ""
    self.selectedGenreLabel = (args["selectedGenreLabel"] as? String) ?? ""
    self.selectedArea = (args["selectedArea"] as? String) ?? ""
    self.selectedYear = (args["selectedYear"] as? String) ?? ""
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    guard !resolved else { return }
    resolved = true
    let cb = completion
    completion = nil
    let id = navIdentity
    if Thread.isMainThread {
      if let id = id { MarcoNativeSheetCoordinator.didFinish(identity: id) }
      cb?(nil)
    } else {
      DispatchQueue.main.async {
        if let id = id { MarcoNativeSheetCoordinator.didFinish(identity: id) }
        cb?(nil)
      }
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      view.backgroundColor = .clear
    } else {
      view.backgroundColor = MarcoLiquidGlassSupport.isEffectiveDark
        ? UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
        : UIColor.systemGroupedBackground
    }
    #else
    view.backgroundColor = MarcoLiquidGlassSupport.isEffectiveDark
      ? UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
      : UIColor.systemGroupedBackground
    #endif

    navigationItem.title = sheetTitle
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: "重置",
      style: .plain,
      target: self,
      action: #selector(resetTapped)
    )
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "完成",
      style: .done,
      target: self,
      action: #selector(doneTapped)
    )

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.alwaysBounceVertical = true
    scrollView.showsVerticalScrollIndicator = false
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      scrollView.cornerConfiguration = .corners(radius: .containerConcentric(minimum: 20.0))
    }
    #endif
    view.addSubview(scrollView)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleSceneActivationChanged),
      name: MarcoLiquidGlassSupport.sceneActivationChangedNotification,
      object: nil
    )

    stackView.axis = .vertical
    stackView.spacing = 18.0
    stackView.alignment = .fill
    stackView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(stackView)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

      stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 12.0),
      stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28.0),
      stackView.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 18.0),
      stackView.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -18.0),
    ])

    if !categories.isEmpty {
      categoryButtons = buildSection(
        title: "类别",
        labels: categories.map { $0.label },
        action: #selector(categoryTapped(_:))
      )
    }
    if !areas.isEmpty {
      areaButtons = buildSection(
        title: "地区",
        labels: areas,
        action: #selector(areaTapped(_:))
      )
    }
    if !years.isEmpty {
      yearButtons = buildSection(
        title: "年份",
        labels: years,
        action: #selector(yearTapped(_:))
      )
    }
    refreshSelectionStyles()
  }

  private func buildSection(title: String, labels: [String], action: Selector) -> [UIButton] {
    let header = UILabel()
    header.text = title
    header.font = UIFont.systemFont(ofSize: 13.5, weight: .semibold)
    header.textColor = MarcoLiquidGlassSupport.isEffectiveDark
      ? UIColor.white.withAlphaComponent(0.72)
      : UIColor.secondaryLabel

    let wrap = MarcoWrapChipContainerView()
    wrap.translatesAutoresizingMaskIntoConstraints = false

    var buttons: [UIButton] = []
    for (idx, label) in labels.enumerated() {
      let btn = UIButton(type: .system)
      btn.tag = idx
      btn.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
      btn.addTarget(self, action: action, for: .touchUpInside)
      applyChipStyle(btn, title: label, selected: false)
      buttons.append(btn)
    }
    wrap.setButtons(buttons)

    let sectionStack = UIStackView(arrangedSubviews: [header, wrap])
    sectionStack.axis = .vertical
    sectionStack.spacing = 10.0
    stackView.addArrangedSubview(sectionStack)
    return buttons
  }

  private func applyChipStyle(_ button: UIButton, title: String, selected: Bool) {
    let dark = MarcoLiquidGlassSupport.isEffectiveDark
    var titleAttr = AttributedString(title)
    titleAttr.font = UIFont.systemFont(ofSize: 13.0, weight: selected ? .bold : .medium)
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      var cfg = selected ? UIButton.Configuration.prominentGlass() : UIButton.Configuration.glass()
      cfg.attributedTitle = titleAttr
      cfg.baseForegroundColor = selected
        ? .white
        : (dark ? UIColor.white.withAlphaComponent(0.88) : UIColor.label)
      if selected {
        cfg.baseBackgroundColor = UIColor.systemBlue
      }
      cfg.cornerStyle = .capsule
      cfg.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 13, bottom: 7, trailing: 13)
      button.configuration = cfg
      button.cornerConfiguration = .capsule()
      return
    }
    #endif
    var cfg = UIButton.Configuration.filled()
    cfg.attributedTitle = titleAttr
    cfg.baseForegroundColor = selected
      ? .white
      : (dark ? UIColor.white.withAlphaComponent(0.86) : UIColor.label)
    cfg.baseBackgroundColor = selected
      ? UIColor.systemBlue
      : (dark ? UIColor(white: 0.22, alpha: 0.85) : UIColor.secondarySystemFill)
    cfg.cornerStyle = .capsule
    cfg.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 13, bottom: 7, trailing: 13)
    button.configuration = cfg
  }

  private func refreshSelectionStyles() {
    for (idx, choice) in categories.enumerated() where idx < categoryButtons.count {
      let isSelected: Bool
      switch choice.kind {
      case "all":
        isSelected = selectedCategoryId.isEmpty && selectedGenreLabel.isEmpty
      case "cat":
        isSelected = selectedCategoryId == choice.id
      default:
        isSelected = selectedCategoryId.isEmpty && selectedGenreLabel == choice.label
      }
      applyChipStyle(categoryButtons[idx], title: choice.label, selected: isSelected)
    }
    for (idx, area) in areas.enumerated() where idx < areaButtons.count {
      let isSelected = (selectedArea.isEmpty && area == "全部") || selectedArea == area
      applyChipStyle(areaButtons[idx], title: area, selected: isSelected)
    }
    for (idx, yr) in years.enumerated() where idx < yearButtons.count {
      let isSelected = (selectedYear.isEmpty && yr == "全部") || selectedYear == yr
      applyChipStyle(yearButtons[idx], title: yr, selected: isSelected)
    }
    let hasAny = !selectedCategoryId.isEmpty || !selectedGenreLabel.isEmpty || !selectedArea.isEmpty || !selectedYear.isEmpty
    navigationItem.leftBarButtonItem?.isEnabled = hasAny
  }

  @objc private func categoryTapped(_ sender: UIButton) {
    let idx = sender.tag
    guard idx >= 0, idx < categories.count else { return }
    let choice = categories[idx]
    switch choice.kind {
    case "all":
      selectedCategoryId = ""
      selectedGenreLabel = ""
    case "cat":
      selectedCategoryId = choice.id
      selectedGenreLabel = ""
    default:
      selectedCategoryId = ""
      selectedGenreLabel = choice.label
    }
    UISelectionFeedbackGenerator().selectionChanged()
    refreshSelectionStyles()
  }

  @objc private func areaTapped(_ sender: UIButton) {
    let idx = sender.tag
    guard idx >= 0, idx < areas.count else { return }
    let val = areas[idx]
    selectedArea = (val == "全部") ? "" : val
    UISelectionFeedbackGenerator().selectionChanged()
    refreshSelectionStyles()
  }

  @objc private func yearTapped(_ sender: UIButton) {
    let idx = sender.tag
    guard idx >= 0, idx < years.count else { return }
    let val = years[idx]
    selectedYear = (val == "全部") ? "" : val
    UISelectionFeedbackGenerator().selectionChanged()
    refreshSelectionStyles()
  }

  @objc private func resetTapped() {
    selectedCategoryId = ""
    selectedGenreLabel = ""
    selectedArea = ""
    selectedYear = ""
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    refreshSelectionStyles()
  }

  @objc private func handleSceneActivationChanged() {
    let active = MarcoLiquidGlassSupport.isSceneActive
    UIView.animate(withDuration: 0.18) {
      self.view.alpha = active ? 1.0 : 0.90
    }
  }

  @objc private func doneTapped() {
    finish(applied: true)
    dismiss(animated: true, completion: nil)
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    finish(applied: true)
  }

  private func finish(applied: Bool) {
    guard !resolved else { return }
    resolved = true
    if let id = navIdentity {
      MarcoNativeSheetCoordinator.didFinish(identity: id)
    }
    let cb = completion
    completion = nil
    if !applied {
      cb?(nil)
      return
    }
    cb?([
      "categoryId": selectedCategoryId,
      "genreLabel": selectedGenreLabel,
      "area": selectedArea,
      "year": selectedYear,
    ])
  }
}

// MARK: - Native iOS 26 Centered Liquid Glass Privacy Passcode Modal

private final class MarcoNativePinSheetController: UIViewController {
  private let sessionId: String
  private let mode: String // "verify" | "set"
  private let initialTitle: String
  private let initialSubtitle: String
  private let confirmTitle: String
  private let confirmSubtitle: String
  private let pinLength: Int
  private let loadingText: String
  private let mismatchError: String

  private var firstPin: String = ""
  private var enteredPin: String = ""
  private var confirming: Bool = false
  private var isBusy: Bool = false
  private var errorMessage: String?

  private let backdropControl = UIControl()
  private let cardShadowView = UIView()
  private var cardEffectView: UIVisualEffectView!
  private let scrollView = UIScrollView()
  private let contentView = UIView()
  private let badgeView = UIView()
  private let badgeGradient = CAGradientLayer()
  private let badgeIconView = UIImageView()
  private let badgeSpinner = UIActivityIndicatorView(style: .medium)
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let dotsStack = UIStackView()
  private var dotViews: [UIView] = []
  private let keypadStack = UIStackView()
  private var digitButtons: [UIButton] = []
  private let cancelButton = UIButton(type: .system)
  private let backspaceButton = UIButton(type: .system)

  private var completion: FlutterResult?
  private var resolved = false
  private var didAnimateIn = false
  private var resetWorkItem: DispatchWorkItem?

  static func present(args: [String: Any], completion: @escaping FlutterResult) {
    guard let host = MarcoLiquidGlassSupport.topPresenter() else {
      completion(nil)
      return
    }
    let vc = MarcoNativePinSheetController(args: args, completion: completion)
    vc.modalPresentationStyle = .overFullScreen
    vc.modalTransitionStyle = .crossDissolve
    vc.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    host.present(vc, animated: false, completion: nil)
  }

  init(args: [String: Any], completion: @escaping FlutterResult) {
    self.sessionId = (args["sessionId"] as? String) ?? UUID().uuidString
    self.mode = (args["mode"] as? String) ?? "verify"
    self.initialTitle = (args["title"] as? String) ?? "解锁隐私空间"
    self.initialSubtitle = (args["subtitle"] as? String) ?? "输入设置的密码即可直接进入隐私分组模式"
    self.confirmTitle = (args["confirmTitle"] as? String) ?? "再次输入确认密码"
    self.confirmSubtitle = (args["confirmSubtitle"] as? String) ?? "请再次输入刚才设置的 4 位数字密码"
    let rawLen = (args["pinLength"] as? NSNumber)?.intValue ?? 4
    self.pinLength = max(4, min(rawLen, 8))
    self.loadingText = (args["loadingText"] as? String) ?? (self.mode == "set" ? "正在加密保存密码…" : "正在验证密码…")
    self.mismatchError = (args["mismatchError"] as? String) ?? "两次输入的密码不一致，请重新设置"
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    resetWorkItem?.cancel()
    finish(succeeded: false)
  }

  override var canBecomeFirstResponder: Bool {
    return true
  }

  override var keyCommands: [UIKeyCommand]? {
    var cmds: [UIKeyCommand] = []
    for d in 0...9 {
      cmds.append(UIKeyCommand(input: "\(d)", modifierFlags: [], action: #selector(handleDigitKeyCommand(_:))))
    }
    cmds.append(UIKeyCommand(input: "\u{8}", modifierFlags: [], action: #selector(backspaceTapped)))
    cmds.append(UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelTapped)))
    return cmds
  }

  private var isDarkPin: Bool {
    return MarcoLiquidGlassSupport.isEffectiveDark(for: isViewLoaded ? view : nil)
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      applyPinTheme()
      refreshUI(animatedDotIndex: nil)
    }
  }

  private func applyPinTheme() {
    let dark = isDarkPin
    let style = MarcoLiquidGlassSupport.interfaceStyle
    overrideUserInterfaceStyle = style
    cardEffectView.overrideUserInterfaceStyle = style
    backdropControl.backgroundColor = dark
      ? UIColor.black.withAlphaComponent(0.58)
      : UIColor.black.withAlphaComponent(0.32)
    cardShadowView.layer.shadowOpacity = dark ? 0.45 : 0.22
    cardEffectView.layer.borderColor = (dark
      ? UIColor.white.withAlphaComponent(0.18)
      : UIColor.black.withAlphaComponent(0.10)).cgColor
    titleLabel.textColor = dark ? .white : UIColor.label
    for btn in digitButtons {
      btn.overrideUserInterfaceStyle = style
      if var cfg = btn.configuration {
        cfg.baseForegroundColor = dark ? .white : UIColor.label
        if #unavailable(iOS 26.0) {
          cfg.baseBackgroundColor = dark
            ? UIColor(white: 0.22, alpha: 0.85)
            : UIColor.secondarySystemFill
        }
        btn.configuration = cfg
      }
    }
    cancelButton.overrideUserInterfaceStyle = style
    if var cfg = cancelButton.configuration {
      cfg.baseForegroundColor = dark
        ? UIColor.white.withAlphaComponent(0.78)
        : UIColor.secondaryLabel
      cancelButton.configuration = cfg
    }
    backspaceButton.overrideUserInterfaceStyle = style
    if var cfg = backspaceButton.configuration {
      cfg.baseForegroundColor = dark
        ? UIColor.white.withAlphaComponent(0.84)
        : UIColor.label
      backspaceButton.configuration = cfg
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    let style = MarcoLiquidGlassSupport.interfaceStyle
    let dark = isDarkPin
    overrideUserInterfaceStyle = style
    view.backgroundColor = .clear

    backdropControl.backgroundColor = dark
      ? UIColor.black.withAlphaComponent(0.58)
      : UIColor.black.withAlphaComponent(0.32)
    backdropControl.translatesAutoresizingMaskIntoConstraints = false
    backdropControl.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
    view.addSubview(backdropControl)

    cardShadowView.backgroundColor = .clear
    cardShadowView.translatesAutoresizingMaskIntoConstraints = false
    cardShadowView.layer.shadowColor = UIColor.black.cgColor
    cardShadowView.layer.shadowOpacity = dark ? 0.45 : 0.22
    cardShadowView.layer.shadowRadius = 28.0
    cardShadowView.layer.shadowOffset = CGSize(width: 0, height: 14)
    view.addSubview(cardShadowView)

    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      cardEffectView = UIVisualEffectView(effect: glass)
    } else {
      cardEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    }
    #else
    cardEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    #endif
    cardEffectView.overrideUserInterfaceStyle = style
    cardEffectView.translatesAutoresizingMaskIntoConstraints = false
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      cardEffectView.cornerConfiguration = .corners(radius: .containerConcentric(minimum: 26.0))
    } else {
      cardEffectView.layer.cornerRadius = 34.0
      cardEffectView.layer.cornerCurve = .continuous
      cardEffectView.clipsToBounds = true
    }
    #else
    cardEffectView.layer.cornerRadius = 34.0
    cardEffectView.layer.cornerCurve = .continuous
    cardEffectView.clipsToBounds = true
    #endif
    cardEffectView.layer.borderWidth = 0.65
    cardEffectView.layer.borderColor = (dark
      ? UIColor.white.withAlphaComponent(0.18)
      : UIColor.black.withAlphaComponent(0.10)).cgColor
    cardShadowView.addSubview(cardEffectView)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handlePinSceneActivationChanged),
      name: MarcoLiquidGlassSupport.sceneActivationChangedNotification,
      object: nil
    )

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.alwaysBounceVertical = false
    cardEffectView.contentView.addSubview(scrollView)

    contentView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(contentView)

    // Shield badge
    badgeView.translatesAutoresizingMaskIntoConstraints = false
    badgeView.layer.cornerRadius = 25.0
    badgeView.layer.masksToBounds = false
    badgeView.layer.shadowColor = UIColor(red: 0.545, green: 0.361, blue: 0.965, alpha: 1.0).cgColor
    badgeView.layer.shadowOpacity = 0.45
    badgeView.layer.shadowRadius = 14.0
    badgeView.layer.shadowOffset = CGSize(width: 0, height: 4)

    badgeGradient.colors = [
      UIColor(red: 0.545, green: 0.361, blue: 0.965, alpha: 1.0).cgColor,
      UIColor(red: 0.310, green: 0.275, blue: 0.898, alpha: 1.0).cgColor,
    ]
    badgeGradient.startPoint = CGPoint(x: 0.0, y: 0.0)
    badgeGradient.endPoint = CGPoint(x: 1.0, y: 1.0)
    badgeGradient.cornerRadius = 25.0
    badgeView.layer.insertSublayer(badgeGradient, at: 0)

    let shieldCfg = UIImage.SymbolConfiguration(pointSize: 22.0, weight: .semibold)
    badgeIconView.image = UIImage(systemName: "lock.shield.fill", withConfiguration: shieldCfg)
    badgeIconView.tintColor = .white
    badgeIconView.contentMode = .scaleAspectFit
    badgeIconView.translatesAutoresizingMaskIntoConstraints = false
    badgeView.addSubview(badgeIconView)

    badgeSpinner.color = .white
    badgeSpinner.hidesWhenStopped = true
    badgeSpinner.translatesAutoresizingMaskIntoConstraints = false
    badgeView.addSubview(badgeSpinner)

    contentView.addSubview(badgeView)

    // Title & subtitle
    titleLabel.font = UIFont.systemFont(ofSize: 19.0, weight: .bold)
    titleLabel.textColor = dark ? .white : UIColor.label
    titleLabel.textAlignment = .center
    titleLabel.numberOfLines = 1
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(titleLabel)

    subtitleLabel.font = UIFont.systemFont(ofSize: 12.5, weight: .regular)
    subtitleLabel.textColor = dark ? UIColor.white.withAlphaComponent(0.74) : UIColor.secondaryLabel
    subtitleLabel.textAlignment = .center
    subtitleLabel.numberOfLines = 2
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(subtitleLabel)

    // PIN dots
    dotsStack.axis = .horizontal
    dotsStack.alignment = .center
    dotsStack.spacing = pinLength > 6 ? 10.0 : 15.0
    dotsStack.translatesAutoresizingMaskIntoConstraints = false
    for _ in 0..<pinLength {
      let dot = UIView()
      dot.translatesAutoresizingMaskIntoConstraints = false
      dot.layer.cornerRadius = 7.0
      dot.layer.borderWidth = 1.2
      NSLayoutConstraint.activate([
        dot.widthAnchor.constraint(equalToConstant: 14.0),
        dot.heightAnchor.constraint(equalToConstant: 14.0),
      ])
      dotsStack.addArrangedSubview(dot)
      dotViews.append(dot)
    }
    contentView.addSubview(dotsStack)

    // 3x4 Liquid Glass Keypad — adapt smoothly to iPhone Duo 5.4" outer display (678pt),
    // inner/outer landscape, and narrow Split View panes (< 360pt) without UIScreen.main.
    let winBounds = MarcoLiquidGlassSupport.activeWindowBounds(for: view)
    let isCompactSize = winBounds.height < 690.0 || winBounds.width < 360.0
    let keySize: CGFloat = isCompactSize ? 60.0 : 68.0
    let rowSpacing: CGFloat = isCompactSize ? 10.0 : 12.0
    let colSpacing: CGFloat = isCompactSize ? 14.0 : 20.0

    keypadStack.axis = .vertical
    keypadStack.alignment = .center
    keypadStack.spacing = rowSpacing
    keypadStack.translatesAutoresizingMaskIntoConstraints = false

    let digitRows = [
      ["1", "2", "3"],
      ["4", "5", "6"],
      ["7", "8", "9"],
    ]
    for row in digitRows {
      let rowStack = UIStackView()
      rowStack.axis = .horizontal
      rowStack.alignment = .center
      rowStack.spacing = colSpacing
      for digit in row {
        let btn = makeDigitButton(digit: digit, size: keySize)
        digitButtons.append(btn)
        rowStack.addArrangedSubview(btn)
      }
      keypadStack.addArrangedSubview(rowStack)
    }

    // Bottom row: Cancel | 0 | Backspace
    let bottomRow = UIStackView()
    bottomRow.axis = .horizontal
    bottomRow.alignment = .center
    bottomRow.spacing = colSpacing

    configureCancelButton(size: keySize)
    let zeroBtn = makeDigitButton(digit: "0", size: keySize)
    digitButtons.append(zeroBtn)
    configureBackspaceButton(size: keySize)

    bottomRow.addArrangedSubview(cancelButton)
    bottomRow.addArrangedSubview(zeroBtn)
    bottomRow.addArrangedSubview(backspaceButton)
    keypadStack.addArrangedSubview(bottomRow)
    contentView.addSubview(keypadStack)

    let preferredCardWidth = cardShadowView.widthAnchor.constraint(equalToConstant: 332.0)
    preferredCardWidth.priority = UILayoutPriority(999)
    let fitScrollHeight = scrollView.heightAnchor.constraint(equalTo: contentView.heightAnchor)
    fitScrollHeight.priority = .defaultHigh

    NSLayoutConstraint.activate([
      backdropControl.topAnchor.constraint(equalTo: view.topAnchor),
      backdropControl.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      backdropControl.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      backdropControl.trailingAnchor.constraint(equalTo: view.trailingAnchor),

      cardShadowView.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
      cardShadowView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
      preferredCardWidth,
      cardShadowView.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 18.0),
      cardShadowView.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -18.0),
      cardShadowView.heightAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.heightAnchor, constant: -32.0),

      cardEffectView.topAnchor.constraint(equalTo: cardShadowView.topAnchor),
      cardEffectView.bottomAnchor.constraint(equalTo: cardShadowView.bottomAnchor),
      cardEffectView.leadingAnchor.constraint(equalTo: cardShadowView.leadingAnchor),
      cardEffectView.trailingAnchor.constraint(equalTo: cardShadowView.trailingAnchor),

      scrollView.topAnchor.constraint(equalTo: cardEffectView.contentView.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: cardEffectView.contentView.bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: cardEffectView.contentView.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: cardEffectView.contentView.trailingAnchor),
      fitScrollHeight,

      contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

      badgeView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24.0),
      badgeView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      badgeView.widthAnchor.constraint(equalToConstant: 50.0),
      badgeView.heightAnchor.constraint(equalToConstant: 50.0),

      badgeIconView.centerXAnchor.constraint(equalTo: badgeView.centerXAnchor),
      badgeIconView.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),
      badgeSpinner.centerXAnchor.constraint(equalTo: badgeView.centerXAnchor),
      badgeSpinner.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),

      titleLabel.topAnchor.constraint(equalTo: badgeView.bottomAnchor, constant: 12.0),
      titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22.0),
      titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22.0),

      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5.0),
      subtitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24.0),
      subtitleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24.0),

      dotsStack.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 18.0),
      dotsStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

      keypadStack.topAnchor.constraint(equalTo: dotsStack.bottomAnchor, constant: 22.0),
      keypadStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      keypadStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -22.0),
    ])

    backdropControl.alpha = 0.0
    cardShadowView.alpha = 0.0
    cardShadowView.transform = CGAffineTransform(scaleX: 0.90, y: 0.90)
    refreshUI(animatedDotIndex: nil)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    becomeFirstResponder()
    guard !didAnimateIn else { return }
    didAnimateIn = true
    MarcoLiquidGlassSupport.animateSpring(duration: 0.36, bounce: 0.14) {
      self.backdropControl.alpha = 1.0
      self.cardShadowView.alpha = 1.0
      self.cardShadowView.transform = .identity
    }
  }

  @objc private func handlePinSceneActivationChanged() {
    let active = MarcoLiquidGlassSupport.isSceneActive
    UIView.animate(withDuration: 0.18) {
      self.cardEffectView.alpha = active ? 1.0 : 0.90
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    badgeGradient.frame = badgeView.bounds
  }

  override func viewWillTransition(
    to size: CGSize,
    with coordinator: UIViewControllerTransitionCoordinator
  ) {
    super.viewWillTransition(to: size, with: coordinator)
    coordinator.animate(alongsideTransition: { [weak self] _ in
      self?.view.setNeedsLayout()
      self?.view.layoutIfNeeded()
    }, completion: nil)
  }

  private func makeDigitButton(digit: String, size: CGFloat) -> UIButton {
    let dark = isDarkPin
    let btn = UIButton(type: .system)
    btn.translatesAutoresizingMaskIntoConstraints = false
    btn.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    btn.tag = Int(digit) ?? 0
    btn.accessibilityLabel = digit
    var titleAttr = AttributedString(digit)
    titleAttr.font = UIFont.monospacedDigitSystemFont(ofSize: 28.0, weight: .medium)
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      var cfg = UIButton.Configuration.glass()
      cfg.attributedTitle = titleAttr
      cfg.baseForegroundColor = dark ? .white : UIColor.label
      cfg.cornerStyle = .capsule
      cfg.contentInsets = .zero
      btn.configuration = cfg
      btn.cornerConfiguration = .capsule()
    } else {
      var cfg = UIButton.Configuration.filled()
      cfg.attributedTitle = titleAttr
      cfg.baseForegroundColor = dark ? .white : UIColor.label
      cfg.baseBackgroundColor = dark
        ? UIColor(white: 0.22, alpha: 0.85)
        : UIColor.secondarySystemFill
      cfg.cornerStyle = .capsule
      cfg.contentInsets = .zero
      btn.configuration = cfg
    }
    #else
    var cfg = UIButton.Configuration.filled()
    cfg.attributedTitle = titleAttr
    cfg.baseForegroundColor = dark ? .white : UIColor.label
    cfg.baseBackgroundColor = dark
      ? UIColor(white: 0.22, alpha: 0.85)
      : UIColor.secondarySystemFill
    cfg.cornerStyle = .capsule
    cfg.contentInsets = .zero
    btn.configuration = cfg
    #endif
    btn.addTarget(self, action: #selector(digitTapped(_:)), for: .touchUpInside)
    NSLayoutConstraint.activate([
      btn.widthAnchor.constraint(equalToConstant: size),
      btn.heightAnchor.constraint(equalToConstant: size),
    ])
    return btn
  }

  private func configureCancelButton(size: CGFloat) {
    let dark = isDarkPin
    cancelButton.translatesAutoresizingMaskIntoConstraints = false
    cancelButton.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    cancelButton.accessibilityLabel = "取消"
    var titleAttr = AttributedString("取消")
    titleAttr.font = UIFont.systemFont(ofSize: 16.0, weight: .semibold)
    var cfg = UIButton.Configuration.plain()
    cfg.attributedTitle = titleAttr
    cfg.baseForegroundColor = dark
      ? UIColor.white.withAlphaComponent(0.78)
      : UIColor.secondaryLabel
    cfg.contentInsets = .zero
    cancelButton.configuration = cfg
    cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
    NSLayoutConstraint.activate([
      cancelButton.widthAnchor.constraint(equalToConstant: size),
      cancelButton.heightAnchor.constraint(equalToConstant: size),
    ])
  }

  private func configureBackspaceButton(size: CGFloat) {
    let dark = isDarkPin
    backspaceButton.translatesAutoresizingMaskIntoConstraints = false
    backspaceButton.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    backspaceButton.accessibilityLabel = "删除"
    let symCfg = UIImage.SymbolConfiguration(pointSize: 22.0, weight: .medium)
    var cfg = UIButton.Configuration.plain()
    cfg.image = UIImage(systemName: "delete.left.fill", withConfiguration: symCfg)
    cfg.baseForegroundColor = dark
      ? UIColor.white.withAlphaComponent(0.84)
      : UIColor.label
    cfg.contentInsets = .zero
    backspaceButton.configuration = cfg
    backspaceButton.addTarget(self, action: #selector(backspaceTapped), for: .touchUpInside)
    NSLayoutConstraint.activate([
      backspaceButton.widthAnchor.constraint(equalToConstant: size),
      backspaceButton.heightAnchor.constraint(equalToConstant: size),
    ])
  }

  private func refreshUI(animatedDotIndex: Int?) {
    let dark = isDarkPin
    titleLabel.text = (mode == "set" && confirming) ? confirmTitle : initialTitle
    titleLabel.textColor = dark ? .white : UIColor.label
    let hasError = !(errorMessage?.isEmpty ?? true)
    if isBusy {
      subtitleLabel.text = loadingText
      subtitleLabel.textColor = dark ? UIColor.white.withAlphaComponent(0.92) : UIColor.label
    } else if hasError {
      subtitleLabel.text = errorMessage
      subtitleLabel.textColor = UIColor.systemRed
    } else {
      subtitleLabel.text = (mode == "set" && confirming) ? confirmSubtitle : initialSubtitle
      subtitleLabel.textColor = dark ? UIColor.white.withAlphaComponent(0.72) : UIColor.secondaryLabel
    }

    badgeIconView.isHidden = isBusy
    if isBusy {
      badgeSpinner.startAnimating()
    } else {
      badgeSpinner.stopAnimating()
    }

    let filledColor = hasError
      ? UIColor.systemRed
      : (dark
          ? UIColor(red: 0.769, green: 0.710, blue: 0.992, alpha: 1.0)
          : UIColor(red: 0.486, green: 0.227, blue: 0.929, alpha: 1.0))
    let filledBorder = hasError
      ? UIColor.systemRed
      : (dark
          ? UIColor(red: 0.655, green: 0.545, blue: 0.980, alpha: 1.0)
          : UIColor(red: 0.427, green: 0.157, blue: 0.851, alpha: 1.0))
    let emptyFill = dark
      ? UIColor.white.withAlphaComponent(0.12)
      : UIColor.black.withAlphaComponent(0.06)
    let emptyBorder = dark
      ? UIColor.white.withAlphaComponent(0.32)
      : UIColor.black.withAlphaComponent(0.24)

    for (idx, dot) in dotViews.enumerated() {
      let filled = idx < enteredPin.count
      dot.backgroundColor = filled ? filledColor : emptyFill
      dot.layer.borderColor = (filled ? filledBorder : emptyBorder).cgColor
      if filled {
        dot.layer.shadowColor = (hasError ? UIColor.systemRed : UIColor(red: 0.545, green: 0.361, blue: 0.965, alpha: 1.0)).cgColor
        dot.layer.shadowOpacity = 0.65
        dot.layer.shadowRadius = 7.0
        dot.layer.shadowOffset = .zero
      } else {
        dot.layer.shadowOpacity = 0.0
      }
      if animatedDotIndex == idx {
        dot.transform = CGAffineTransform(scaleX: 1.32, y: 1.32)
        UIView.animate(
          withDuration: 0.22,
          delay: 0,
          usingSpringWithDamping: 0.62,
          initialSpringVelocity: 0.7,
          options: [.allowUserInteraction],
          animations: { dot.transform = .identity },
          completion: nil
        )
      }
    }

    backspaceButton.alpha = (enteredPin.isEmpty || isBusy) ? 0.35 : 1.0
    backspaceButton.isEnabled = !enteredPin.isEmpty && !isBusy
    for btn in digitButtons {
      btn.isEnabled = !isBusy
    }
  }

  private func shakeDots() {
    let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
    anim.timingFunction = CAMediaTimingFunction(name: .linear)
    anim.duration = 0.36
    anim.values = [-12.0, 12.0, -9.0, 9.0, -5.0, 5.0, 0.0]
    dotsStack.layer.add(anim, forKey: "marcoPinShake")
  }

  @objc private func handleDigitKeyCommand(_ cmd: UIKeyCommand) {
    guard let input = cmd.input else { return }
    appendDigit(input)
  }

  @objc private func digitTapped(_ sender: UIButton) {
    appendDigit("\(sender.tag)")
  }

  private func appendDigit(_ digit: String) {
    guard !isBusy, !resolved, enteredPin.count < pinLength else { return }
    resetWorkItem?.cancel()
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    errorMessage = nil
    enteredPin.append(digit)
    refreshUI(animatedDotIndex: enteredPin.count - 1)

    guard enteredPin.count == pinLength else { return }
    let completedPin = enteredPin

    if mode == "set" {
      if !confirming {
        isBusy = true
        let work = DispatchWorkItem { [weak self] in
          guard let self = self, !self.resolved else { return }
          self.isBusy = false
          self.firstPin = completedPin
          self.enteredPin = ""
          self.confirming = true
          UIView.transition(
            with: self.contentView,
            duration: 0.22,
            options: [.transitionCrossDissolve, .allowUserInteraction],
            animations: { self.refreshUI(animatedDotIndex: nil) },
            completion: nil
          )
        }
        resetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
        return
      }
      if completedPin != firstPin {
        triggerError(mismatchError, resetToFirstStep: true)
        return
      }
    }

    submitPinToFlutter(completedPin)
  }

  private func submitPinToFlutter(_ pin: String) {
    guard let channel = MarcoLiquidGlassSupport.bridgeChannel else {
      dismissAnimated(succeeded: false)
      return
    }
    isBusy = true
    errorMessage = nil
    refreshUI(animatedDotIndex: nil)

    channel.invokeMethod(
      "privacyPinCallback",
      arguments: [
        "sessionId": sessionId,
        "mode": mode,
        "pin": pin,
      ]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self, !self.resolved else { return }
        let dict = response as? [String: Any]
        let ok = (dict?["ok"] as? Bool) ?? false
        if ok {
          UINotificationFeedbackGenerator().notificationOccurred(.success)
          self.dismissAnimated(succeeded: true)
        } else {
          let errText = (dict?["error"] as? String) ?? "密码错误，请重新输入"
          self.triggerError(errText, resetToFirstStep: self.mode == "set")
        }
      }
    }
  }

  private func triggerError(_ message: String, resetToFirstStep: Bool) {
    UINotificationFeedbackGenerator().notificationOccurred(.error)
    isBusy = false
    errorMessage = message
    refreshUI(animatedDotIndex: nil)
    shakeDots()

    resetWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self = self, !self.resolved else { return }
      self.enteredPin = ""
      if resetToFirstStep {
        self.firstPin = ""
        self.confirming = false
      }
      self.refreshUI(animatedDotIndex: nil)
    }
    resetWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.36, execute: work)
  }

  @objc private func backspaceTapped() {
    guard !isBusy, !enteredPin.isEmpty else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    errorMessage = nil
    enteredPin.removeLast()
    refreshUI(animatedDotIndex: nil)
  }

  @objc private func cancelTapped() {
    dismissAnimated(succeeded: false)
  }

  private func dismissAnimated(succeeded: Bool) {
    finish(succeeded: succeeded)
    UIView.animate(
      withDuration: 0.18,
      delay: 0,
      options: [.curveEaseIn],
      animations: {
        self.backdropControl.alpha = 0.0
        self.cardShadowView.alpha = 0.0
        self.cardShadowView.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
      }
    ) { _ in
      self.dismiss(animated: false, completion: nil)
    }
  }

  private func finish(succeeded: Bool) {
    guard !resolved else { return }
    resolved = true
    let cb = completion
    completion = nil
    cb?(succeeded)
  }
}

// MARK: - 1. Native iOS 26 Floating Liquid Glass Dock (Full 62pt 4+1 & Scroll-Collapsed Logo Menu)

private final class MarcoNativeDockFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return MarcoNativeDockPlatformView(
      frame: frame,
      viewId: viewId,
      arguments: args as? [String: Any],
      messenger: messenger
    )
  }
}

private final class MarcoTraitAwareHostView: UIView {
  var onTraitChanged: (() -> Void)?

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      onTraitChanged?()
    }
  }
}

/// Bespoke 24x24pt CoreAnimation layered vector tab icon for the 4 bottom Dock
/// tabs (`主页` / `直播` / `片库` / `设置`) with rich dual-tone selected styling
/// and distinctive per-tab spring micro-animations (cinema screen pop + sparkle,
/// live crimson broadcast wave ripple, 3-layer library card fan, and 60°
/// mechanical precision gear turn). Adapts natively to Light & Dark Mode.
private final class MarcoAnimatedTabIconView: UIView {
  enum Kind: String {
    case home
    case live
    case library
    case settings
    case fallback

    static func resolve(kind: String?, symbol: String, label: String) -> Kind {
      if let k = kind?.lowercased(), let parsed = Kind(rawValue: k) {
        return parsed
      }
      let sym = symbol.lowercased()
      if sym.contains("play.rectangle") || sym.contains("house") || label.contains("主页") {
        return .home
      }
      if sym.contains("radiowaves") || sym.contains("antenna") || sym.contains("tv") || label.contains("直播") {
        return .live
      }
      if sym.contains("square.stack") || sym.contains("film") || sym.contains("bookmark") || label.contains("片库") {
        return .library
      }
      if sym.contains("gear") || sym.contains("slider") || label.contains("设置") {
        return .settings
      }
      return .fallback
    }
  }

  private let canvasLayer = CALayer()
  // Home layers
  private let homeScreenLayer = CAShapeLayer()
  private let homePlayLayer = CAShapeLayer()
  private let homeStandLayer = CAShapeLayer()
  private let homeSparkleLayer = CAShapeLayer()
  // Live layers
  private let liveOuterWaveLayer = CAShapeLayer()
  private let liveInnerWaveLayer = CAShapeLayer()
  private let liveStandLayer = CAShapeLayer()
  private let liveHaloLayer = CAShapeLayer()
  private let liveBeaconLayer = CAShapeLayer()
  // Library layers
  private let libBackCardLayer = CAShapeLayer()
  private let libMidCardLayer = CAShapeLayer()
  private let libFrontCardLayer = CAShapeLayer()
  private let libBookmarkLayer = CAShapeLayer()
  // Settings layers
  private let settingsGearLayer = CAShapeLayer()
  private let settingsHoleLayer = CAShapeLayer()
  private let settingsJewelLayer = CAShapeLayer()
  // Fallback SF Symbol
  private let fallbackImageView = UIImageView()

  private var currentKind: Kind = .home
  private var isSelectedState: Bool = false
  private var isDarkState: Bool = true
  private var fallbackSymbol: String = "circle"

  override var intrinsicContentSize: CGSize {
    return CGSize(width: 24.0, height: 24.0)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = false
    clipsToBounds = false

    canvasLayer.frame = CGRect(x: 0.0, y: 0.0, width: 24.0, height: 24.0)
    canvasLayer.masksToBounds = false
    layer.addSublayer(canvasLayer)

    let scale = max(MarcoLiquidGlassSupport.activeWindow()?.windowScene?.screen.scale ?? 3.0, 2.0)
    func setup(_ sl: CAShapeLayer, pivot: CGPoint) {
      sl.bounds = CGRect(x: 0.0, y: 0.0, width: 24.0, height: 24.0)
      sl.anchorPoint = CGPoint(x: pivot.x / 24.0, y: pivot.y / 24.0)
      sl.position = pivot
      sl.contentsScale = scale
      sl.lineCap = .round
      sl.lineJoin = .round
      sl.isHidden = true
      canvasLayer.addSublayer(sl)
    }

    setup(homeStandLayer, pivot: CGPoint(x: 12.0, y: 19.6))
    setup(homeScreenLayer, pivot: CGPoint(x: 12.0, y: 10.7))
    setup(homePlayLayer, pivot: CGPoint(x: 12.2, y: 10.7))
    setup(homeSparkleLayer, pivot: CGPoint(x: 20.6, y: 3.4))

    setup(liveOuterWaveLayer, pivot: CGPoint(x: 12.0, y: 10.6))
    setup(liveInnerWaveLayer, pivot: CGPoint(x: 12.0, y: 10.6))
    setup(liveStandLayer, pivot: CGPoint(x: 12.0, y: 17.5))
    setup(liveHaloLayer, pivot: CGPoint(x: 12.0, y: 10.6))
    setup(liveBeaconLayer, pivot: CGPoint(x: 12.0, y: 10.6))

    setup(libBackCardLayer, pivot: CGPoint(x: 12.0, y: 4.1))
    setup(libMidCardLayer, pivot: CGPoint(x: 12.0, y: 7.2))
    setup(libFrontCardLayer, pivot: CGPoint(x: 12.0, y: 15.2))
    setup(libBookmarkLayer, pivot: CGPoint(x: 12.0, y: 9.4))

    setup(settingsGearLayer, pivot: CGPoint(x: 12.0, y: 12.0))
    setup(settingsHoleLayer, pivot: CGPoint(x: 12.0, y: 12.0))
    setup(settingsJewelLayer, pivot: CGPoint(x: 12.0, y: 12.0))

    fallbackImageView.contentMode = .scaleAspectFit
    fallbackImageView.isHidden = true
    fallbackImageView.frame = CGRect(x: 0.0, y: 0.0, width: 24.0, height: 24.0)
    addSubview(fallbackImageView)

    buildStaticPaths()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    let displayScale = window?.windowScene?.screen.scale ?? traitCollection.displayScale
    guard displayScale >= 1.0 else { return }
    for sub in canvasLayer.sublayers ?? [] {
      sub.contentsScale = displayScale
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let sx = bounds.width > 0 ? bounds.width / 24.0 : 1.0
    let sy = bounds.height > 0 ? bounds.height / 24.0 : 1.0
    let s = min(sx, sy)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    canvasLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    canvasLayer.transform = CATransform3DMakeScale(s, s, 1.0)
    fallbackImageView.frame = bounds
    CATransaction.commit()
  }

  private func buildStaticPaths() {
    // 1. Home: Cinema Screen + Sculpted Play Triangle + Curved Stand + 4-pt Sparkle
    homeScreenLayer.path = UIBezierPath(
      roundedRect: CGRect(x: 2.3, y: 3.9, width: 19.4, height: 13.6),
      cornerRadius: 4.3
    ).cgPath

    let playPath = UIBezierPath()
    playPath.move(to: CGPoint(x: 10.0, y: 8.3))
    playPath.addLine(to: CGPoint(x: 15.3, y: 10.7))
    playPath.addLine(to: CGPoint(x: 10.0, y: 13.1))
    playPath.close()
    homePlayLayer.path = playPath.cgPath

    let standPath = UIBezierPath()
    standPath.move(to: CGPoint(x: 8.1, y: 20.5))
    standPath.addQuadCurve(to: CGPoint(x: 15.9, y: 20.5), controlPoint: CGPoint(x: 12.0, y: 18.8))
    homeStandLayer.path = standPath.cgPath

    let sparklePath = UIBezierPath()
    let sc = CGPoint(x: 20.6, y: 3.4)
    let sr: Double = 2.75
    let ir: Double = 0.78
    for k in 0..<8 {
      let a = Double(k) * (Double.pi / 4.0)
      let rr = (k % 2 == 0) ? sr : ir
      let pt = CGPoint(
        x: sc.x + CGFloat(Foundation.cos(a) * rr),
        y: sc.y + CGFloat(Foundation.sin(a) * rr)
      )
      if k == 0 { sparklePath.move(to: pt) } else { sparklePath.addLine(to: pt) }
    }
    sparklePath.close()
    homeSparkleLayer.path = sparklePath.cgPath

    // 2. Live: Broadcast Beacon + Dual Concentric Wave Arcs + Dish Stand
    let bc = CGPoint(x: 12.0, y: 10.6)
    let outerArc = UIBezierPath()
    let deg42 = 42.0 * Double.pi / 180.0
    let deg138 = 138.0 * Double.pi / 180.0
    let deg222 = 222.0 * Double.pi / 180.0
    outerArc.addArc(withCenter: bc, radius: 8.5, startAngle: CGFloat(deg138), endAngle: CGFloat(deg222), clockwise: true)
    outerArc.move(to: CGPoint(x: bc.x + CGFloat(Foundation.cos(-deg42) * 8.5), y: bc.y + CGFloat(Foundation.sin(-deg42) * 8.5)))
    outerArc.addArc(withCenter: bc, radius: 8.5, startAngle: CGFloat(-deg42), endAngle: CGFloat(deg42), clockwise: true)
    liveOuterWaveLayer.path = outerArc.cgPath

    let innerArc = UIBezierPath()
    let deg40 = 40.0 * Double.pi / 180.0
    let deg140 = 140.0 * Double.pi / 180.0
    let deg220 = 220.0 * Double.pi / 180.0
    innerArc.addArc(withCenter: bc, radius: 5.25, startAngle: CGFloat(deg140), endAngle: CGFloat(deg220), clockwise: true)
    innerArc.move(to: CGPoint(x: bc.x + CGFloat(Foundation.cos(-deg40) * 5.25), y: bc.y + CGFloat(Foundation.sin(-deg40) * 5.25)))
    innerArc.addArc(withCenter: bc, radius: 5.25, startAngle: CGFloat(-deg40), endAngle: CGFloat(deg40), clockwise: true)
    liveInnerWaveLayer.path = innerArc.cgPath

    let liveStand = UIBezierPath()
    liveStand.move(to: CGPoint(x: 12.0, y: 14.0))
    liveStand.addLine(to: CGPoint(x: 12.0, y: 19.6))
    liveStand.move(to: CGPoint(x: 8.2, y: 20.6))
    liveStand.addQuadCurve(to: CGPoint(x: 15.8, y: 20.6), controlPoint: CGPoint(x: 12.0, y: 18.8))
    liveStandLayer.path = liveStand.cgPath

    liveHaloLayer.path = UIBezierPath(ovalIn: CGRect(x: bc.x - 4.0, y: bc.y - 4.0, width: 8.0, height: 8.0)).cgPath
    liveBeaconLayer.path = UIBezierPath(ovalIn: CGRect(x: bc.x - 2.35, y: bc.y - 2.35, width: 4.7, height: 4.7)).cgPath

    // 3. Library: 3-Layer Film Collection Deck + Bookmark Ribbon
    libBackCardLayer.path = UIBezierPath(
      roundedRect: CGRect(x: 6.6, y: 3.1, width: 10.8, height: 2.0),
      cornerRadius: 1.0
    ).cgPath
    libMidCardLayer.path = UIBezierPath(
      roundedRect: CGRect(x: 4.5, y: 6.1, width: 15.0, height: 2.15),
      cornerRadius: 1.08
    ).cgPath
    libFrontCardLayer.path = UIBezierPath(
      roundedRect: CGRect(x: 2.5, y: 9.4, width: 19.0, height: 11.6),
      cornerRadius: 3.7
    ).cgPath

    let bm = UIBezierPath()
    bm.move(to: CGPoint(x: 9.3, y: 9.4))
    bm.addLine(to: CGPoint(x: 14.7, y: 9.4))
    bm.addLine(to: CGPoint(x: 14.7, y: 16.5))
    bm.addLine(to: CGPoint(x: 12.0, y: 14.4))
    bm.addLine(to: CGPoint(x: 9.3, y: 16.5))
    bm.close()
    libBookmarkLayer.path = bm.cgPath

    // 4. Settings: Sculpted 6-Lobe Apple Precision Gear + Inner Ring + Center Jewel
    let gearPath = buildSculptedGearPath(includeInnerHole: true)
    settingsGearLayer.path = gearPath.cgPath
    settingsGearLayer.fillRule = .evenOdd
    settingsHoleLayer.path = UIBezierPath(ovalIn: CGRect(x: 8.75, y: 8.75, width: 6.5, height: 6.5)).cgPath
    settingsJewelLayer.path = UIBezierPath(ovalIn: CGRect(x: 10.25, y: 10.25, width: 3.5, height: 3.5)).cgPath
  }

  private func buildSculptedGearPath(includeInnerHole: Bool) -> UIBezierPath {
    let path = UIBezierPath()
    let samples = 96
    for i in 0..<samples {
      let th = (2.0 * Double.pi * Double(i)) / Double(samples) - Double.pi * 0.5
      let wave = Foundation.cos(6.0 * th)
      let shaped = (wave >= 0 ? 1.0 : -1.0) * Foundation.pow(abs(wave), 0.54)
      let r = 8.0 + 1.55 * shaped
      let pt = CGPoint(x: 12.0 + r * Foundation.cos(th), y: 12.0 + r * Foundation.sin(th))
      if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
    }
    path.close()
    if includeInnerHole {
      let hole = UIBezierPath(ovalIn: CGRect(x: 8.35, y: 8.35, width: 7.3, height: 7.3))
      path.append(hole)
    }
    return path
  }

  func configure(kind: Kind, selected: Bool, dark: Bool, fallbackSymbol: String) {
    self.currentKind = kind
    self.isSelectedState = selected
    self.isDarkState = dark
    self.fallbackSymbol = fallbackSymbol

    let activePrimary: UIColor = dark
      ? UIColor(red: 0.25, green: 0.65, blue: 1.0, alpha: 1.0)
      : UIColor.systemBlue
    let activeSecondary: UIColor = dark
      ? UIColor(red: 0.46, green: 0.84, blue: 1.0, alpha: 1.0)
      : UIColor(red: 0.22, green: 0.71, blue: 1.0, alpha: 1.0)
    let liveBeaconRed: UIColor = dark
      ? UIColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1.0)
      : UIColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0)
    let inactiveColor: UIColor = dark
      ? UIColor.white.withAlphaComponent(0.70)
      : UIColor(red: 0.17, green: 0.19, blue: 0.23, alpha: 0.74)

    let allShapeLayers: [CAShapeLayer] = [
      homeScreenLayer, homePlayLayer, homeStandLayer, homeSparkleLayer,
      liveOuterWaveLayer, liveInnerWaveLayer, liveStandLayer, liveHaloLayer, liveBeaconLayer,
      libBackCardLayer, libMidCardLayer, libFrontCardLayer, libBookmarkLayer,
      settingsGearLayer, settingsHoleLayer, settingsJewelLayer,
    ]

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for sl in allShapeLayers {
      sl.isHidden = true
    }
    fallbackImageView.isHidden = true

    switch kind {
    case .home:
      homeScreenLayer.isHidden = false
      homePlayLayer.isHidden = false
      homeStandLayer.isHidden = false
      homeSparkleLayer.isHidden = !selected

      if selected {
        homeScreenLayer.fillColor = activePrimary.cgColor
        homeScreenLayer.strokeColor = nil
        homeScreenLayer.lineWidth = 0.0

        homePlayLayer.fillColor = UIColor.white.cgColor
        homePlayLayer.strokeColor = UIColor.white.cgColor
        homePlayLayer.lineWidth = 0.9

        homeStandLayer.fillColor = nil
        homeStandLayer.strokeColor = activeSecondary.cgColor
        homeStandLayer.lineWidth = 2.05

        homeSparkleLayer.fillColor = activeSecondary.cgColor
        homeSparkleLayer.strokeColor = nil
      } else {
        homeScreenLayer.fillColor = nil
        homeScreenLayer.strokeColor = inactiveColor.cgColor
        homeScreenLayer.lineWidth = 1.85

        homePlayLayer.fillColor = nil
        homePlayLayer.strokeColor = inactiveColor.cgColor
        homePlayLayer.lineWidth = 1.55

        homeStandLayer.fillColor = nil
        homeStandLayer.strokeColor = inactiveColor.withAlphaComponent(0.74).cgColor
        homeStandLayer.lineWidth = 1.75
      }

    case .live:
      liveOuterWaveLayer.isHidden = false
      liveInnerWaveLayer.isHidden = false
      liveStandLayer.isHidden = false
      liveBeaconLayer.isHidden = false
      liveHaloLayer.isHidden = !selected

      liveOuterWaveLayer.fillColor = nil
      liveInnerWaveLayer.fillColor = nil
      liveStandLayer.fillColor = nil

      if selected {
        liveOuterWaveLayer.strokeColor = activeSecondary.cgColor
        liveOuterWaveLayer.lineWidth = 1.9
        liveInnerWaveLayer.strokeColor = activePrimary.cgColor
        liveInnerWaveLayer.lineWidth = 1.95
        liveStandLayer.strokeColor = activePrimary.cgColor
        liveStandLayer.lineWidth = 1.95
        liveHaloLayer.fillColor = liveBeaconRed.withAlphaComponent(0.28).cgColor
        liveHaloLayer.strokeColor = nil
        liveBeaconLayer.fillColor = liveBeaconRed.cgColor
        liveBeaconLayer.strokeColor = nil
      } else {
        liveOuterWaveLayer.strokeColor = inactiveColor.withAlphaComponent(0.56).cgColor
        liveOuterWaveLayer.lineWidth = 1.8
        liveInnerWaveLayer.strokeColor = inactiveColor.cgColor
        liveInnerWaveLayer.lineWidth = 1.85
        liveStandLayer.strokeColor = inactiveColor.cgColor
        liveStandLayer.lineWidth = 1.8
        liveBeaconLayer.fillColor = inactiveColor.cgColor
        liveBeaconLayer.strokeColor = nil
      }

    case .library:
      libBackCardLayer.isHidden = false
      libMidCardLayer.isHidden = false
      libFrontCardLayer.isHidden = false
      libBookmarkLayer.isHidden = false

      if selected {
        libBackCardLayer.fillColor = activeSecondary.withAlphaComponent(0.52).cgColor
        libBackCardLayer.strokeColor = nil
        libMidCardLayer.fillColor = activeSecondary.withAlphaComponent(0.84).cgColor
        libMidCardLayer.strokeColor = nil
        libFrontCardLayer.fillColor = activePrimary.cgColor
        libFrontCardLayer.strokeColor = nil
        libFrontCardLayer.lineWidth = 0.0
        libBookmarkLayer.fillColor = UIColor.white.cgColor
        libBookmarkLayer.strokeColor = nil
      } else {
        libBackCardLayer.fillColor = inactiveColor.withAlphaComponent(0.46).cgColor
        libBackCardLayer.strokeColor = nil
        libMidCardLayer.fillColor = inactiveColor.withAlphaComponent(0.72).cgColor
        libMidCardLayer.strokeColor = nil
        libFrontCardLayer.fillColor = nil
        libFrontCardLayer.strokeColor = inactiveColor.cgColor
        libFrontCardLayer.lineWidth = 1.85
        libBookmarkLayer.fillColor = nil
        libBookmarkLayer.strokeColor = inactiveColor.cgColor
        libBookmarkLayer.lineWidth = 1.55
      }

    case .settings:
      settingsGearLayer.isHidden = false
      settingsHoleLayer.isHidden = selected
      settingsJewelLayer.isHidden = !selected

      if selected {
        settingsGearLayer.path = buildSculptedGearPath(includeInnerHole: true).cgPath
        settingsGearLayer.fillColor = activePrimary.cgColor
        settingsGearLayer.strokeColor = nil
        settingsGearLayer.lineWidth = 0.0
        settingsJewelLayer.fillColor = activeSecondary.cgColor
        settingsJewelLayer.strokeColor = nil
      } else {
        settingsGearLayer.path = buildSculptedGearPath(includeInnerHole: false).cgPath
        settingsGearLayer.fillColor = nil
        settingsGearLayer.strokeColor = inactiveColor.cgColor
        settingsGearLayer.lineWidth = 1.85
        settingsHoleLayer.fillColor = nil
        settingsHoleLayer.strokeColor = inactiveColor.cgColor
        settingsHoleLayer.lineWidth = 1.75
      }

    case .fallback:
      fallbackImageView.isHidden = false
      let cfg = UIImage.SymbolConfiguration(pointSize: 20.5, weight: selected ? .semibold : .medium)
      fallbackImageView.image = UIImage(systemName: fallbackSymbol, withConfiguration: cfg)
      fallbackImageView.tintColor = selected ? activePrimary : inactiveColor
    }
    CATransaction.commit()
  }

  /// Plays this tab's signature tactile spring micro-animation on selection.
  func playSelectAnimation() {
    guard !UIAccessibility.isReduceMotionEnabled else { return }
    let now = canvasLayer.convertTime(CACurrentMediaTime(), from: nil)

    func keyframe(
      _ keyPath: String,
      values: [Any],
      times: [NSNumber],
      duration: CFTimeInterval,
      delay: CFTimeInterval = 0.0
    ) -> CAKeyframeAnimation {
      let anim = CAKeyframeAnimation(keyPath: keyPath)
      anim.values = values
      anim.keyTimes = times
      anim.duration = duration
      anim.beginTime = delay > 0 ? now + delay : 0
      anim.fillMode = .backwards
      anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
      return anim
    }

    switch currentKind {
    case .home:
      homeScreenLayer.removeAllAnimations()
      homePlayLayer.removeAllAnimations()
      homeStandLayer.removeAllAnimations()
      homeSparkleLayer.removeAllAnimations()

      homeScreenLayer.add(
        keyframe("transform.scale", values: [0.82, 1.12, 0.97, 1.0], times: [0, 0.42, 0.76, 1.0], duration: 0.52),
        forKey: "marcoHomePop"
      )
      homePlayLayer.add(
        keyframe("transform.translation.x", values: [-2.4, 0.9, -0.2, 0.0], times: [0, 0.46, 0.78, 1.0], duration: 0.52),
        forKey: "marcoHomePlaySlide"
      )
      homePlayLayer.add(
        keyframe("transform.scale", values: [0.55, 1.18, 0.96, 1.0], times: [0, 0.46, 0.78, 1.0], duration: 0.52),
        forKey: "marcoHomePlayScale"
      )
      homeStandLayer.add(
        keyframe("transform.scale.x", values: [0.38, 1.14, 0.98, 1.0], times: [0, 0.48, 0.78, 1.0], duration: 0.48),
        forKey: "marcoHomeStand"
      )
      homeSparkleLayer.add(
        keyframe("transform.scale", values: [0.01, 1.35, 0.92, 1.0], times: [0, 0.52, 0.80, 1.0], duration: 0.56, delay: 0.06),
        forKey: "marcoHomeSparkleScale"
      )
      homeSparkleLayer.add(
        keyframe("transform.rotation.z", values: [-0.78, 0.24, -0.05, 0.0], times: [0, 0.54, 0.82, 1.0], duration: 0.56, delay: 0.06),
        forKey: "marcoHomeSparkleSpin"
      )

    case .live:
      liveBeaconLayer.removeAllAnimations()
      liveHaloLayer.removeAllAnimations()
      liveInnerWaveLayer.removeAllAnimations()
      liveOuterWaveLayer.removeAllAnimations()

      liveBeaconLayer.add(
        keyframe("transform.scale", values: [0.58, 1.38, 0.94, 1.0], times: [0, 0.38, 0.72, 1.0], duration: 0.54),
        forKey: "marcoLiveBeacon"
      )
      liveHaloLayer.add(
        keyframe("transform.scale", values: [0.55, 1.72, 1.08, 1.0], times: [0, 0.45, 0.78, 1.0], duration: 0.64),
        forKey: "marcoLiveHaloScale"
      )
      liveHaloLayer.add(
        keyframe("opacity", values: [0.9, 0.25, 0.85, 1.0], times: [0, 0.48, 0.78, 1.0], duration: 0.64),
        forKey: "marcoLiveHaloFade"
      )
      liveInnerWaveLayer.add(
        keyframe("transform.scale", values: [0.68, 1.16, 0.98, 1.0], times: [0, 0.48, 0.78, 1.0], duration: 0.50, delay: 0.05),
        forKey: "marcoLiveInnerScale"
      )
      liveInnerWaveLayer.add(
        keyframe("opacity", values: [0.22, 1.0, 1.0], times: [0, 0.42, 1.0], duration: 0.50, delay: 0.05),
        forKey: "marcoLiveInnerFade"
      )
      liveOuterWaveLayer.add(
        keyframe("transform.scale", values: [0.64, 1.20, 0.98, 1.0], times: [0, 0.50, 0.80, 1.0], duration: 0.52, delay: 0.13),
        forKey: "marcoLiveOuterScale"
      )
      liveOuterWaveLayer.add(
        keyframe("opacity", values: [0.12, 1.0, 1.0], times: [0, 0.44, 1.0], duration: 0.52, delay: 0.13),
        forKey: "marcoLiveOuterFade"
      )

    case .library:
      libFrontCardLayer.removeAllAnimations()
      libBookmarkLayer.removeAllAnimations()
      libMidCardLayer.removeAllAnimations()
      libBackCardLayer.removeAllAnimations()

      libFrontCardLayer.add(
        keyframe("transform.scale", values: [0.86, 1.09, 0.98, 1.0], times: [0, 0.42, 0.76, 1.0], duration: 0.50),
        forKey: "marcoLibFront"
      )
      libBookmarkLayer.add(
        keyframe("transform.scale.y", values: [0.42, 1.16, 0.96, 1.0], times: [0, 0.46, 0.78, 1.0], duration: 0.50),
        forKey: "marcoLibBookmark"
      )
      libMidCardLayer.add(
        keyframe("transform.translation.y", values: [3.2, -1.5, 0.3, 0.0], times: [0, 0.46, 0.78, 1.0], duration: 0.52, delay: 0.03),
        forKey: "marcoLibMidY"
      )
      libMidCardLayer.add(
        keyframe("transform.scale.x", values: [0.84, 1.06, 0.99, 1.0], times: [0, 0.46, 0.78, 1.0], duration: 0.52, delay: 0.03),
        forKey: "marcoLibMidScale"
      )
      libBackCardLayer.add(
        keyframe("transform.translation.y", values: [5.2, -2.3, 0.4, 0.0], times: [0, 0.48, 0.80, 1.0], duration: 0.54, delay: 0.08),
        forKey: "marcoLibBackY"
      )
      libBackCardLayer.add(
        keyframe("transform.scale.x", values: [0.74, 1.08, 0.98, 1.0], times: [0, 0.48, 0.80, 1.0], duration: 0.54, delay: 0.08),
        forKey: "marcoLibBackScale"
      )

    case .settings:
      settingsGearLayer.removeAllAnimations()
      settingsJewelLayer.removeAllAnimations()

      // 60° (pi/3) clockwise turn aligns cleanly with 6-lobe rotational symmetry!
      let sixtyDeg = CGFloat.pi / 3.0
      settingsGearLayer.add(
        keyframe(
          "transform.rotation.z",
          values: [0.0, sixtyDeg * 1.18, sixtyDeg * 0.95, sixtyDeg],
          times: [0, 0.48, 0.78, 1.0],
          duration: 0.58
        ),
        forKey: "marcoSettingsRotate"
      )
      settingsGearLayer.add(
        keyframe("transform.scale", values: [0.86, 1.11, 0.98, 1.0], times: [0, 0.42, 0.76, 1.0], duration: 0.54),
        forKey: "marcoSettingsScale"
      )
      settingsJewelLayer.add(
        keyframe("transform.scale", values: [0.20, 1.34, 0.94, 1.0], times: [0, 0.48, 0.80, 1.0], duration: 0.54, delay: 0.06),
        forKey: "marcoSettingsJewel"
      )

    case .fallback:
      fallbackImageView.layer.removeAllAnimations()
      fallbackImageView.layer.add(
        keyframe("transform.scale", values: [0.84, 1.14, 0.97, 1.0], times: [0, 0.44, 0.76, 1.0], duration: 0.48),
        forKey: "marcoFallbackBounce"
      )
    }
  }
}

/// Fallback capsule for iOS 15–25 (non-Liquid Glass OS versions).
/// On iOS 26+, `MarcoIos27DockChromeView` renders real `UITabBar` + `UIGlassContainerEffect`
/// + `UIButton(configuration: .glass())`.
private final class MarcoNativeLiquidTabCapsuleView: UIView {
  struct TabSpec {
    let label: String
    let symbol: String
    let selectedSymbol: String
    let kind: MarcoAnimatedTabIconView.Kind
  }

  private final class SlotView: UIView {
    let iconView = MarcoAnimatedTabIconView()
    let titleLabel = UILabel()
    private let stack = UIStackView()

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      isAccessibilityElement = true
      accessibilityTraits = .button

      iconView.translatesAutoresizingMaskIntoConstraints = false

      titleLabel.font = UIFont.systemFont(ofSize: 10.5, weight: .medium)
      titleLabel.textAlignment = .center
      titleLabel.lineBreakMode = .byTruncatingTail
      titleLabel.textColor = UIColor.white.withAlphaComponent(0.72)

      stack.axis = .vertical
      stack.alignment = .center
      stack.spacing = 2.5
      stack.isUserInteractionEnabled = false
      stack.translatesAutoresizingMaskIntoConstraints = false
      stack.addArrangedSubview(iconView)
      stack.addArrangedSubview(titleLabel)
      addSubview(stack)

      NSLayoutConstraint.activate([
        iconView.widthAnchor.constraint(equalToConstant: 24.0),
        iconView.heightAnchor.constraint(equalToConstant: 24.0),
        stack.centerXAnchor.constraint(equalTo: centerXAnchor),
        stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4.0),
        stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4.0),
      ])
    }

    func playSelectedMotion() {
      iconView.playSelectAnimation()
      guard !UIAccessibility.isReduceMotionEnabled else { return }
      titleLabel.transform = CGAffineTransform(translationX: 0, y: 1.6).scaledBy(x: 0.94, y: 0.94)
      UIView.animate(
        withDuration: 0.34,
        delay: 0.0,
        usingSpringWithDamping: 0.68,
        initialSpringVelocity: 0.8,
        options: [.beginFromCurrentState, .allowUserInteraction],
        animations: {
          self.titleLabel.transform = .identity
        },
        completion: nil
      )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }
  }

  private let effectView: UIVisualEffectView
  private let selectionLensView = UIView()
  private let slotsStack = UIStackView()
  private let scrubbingLensShadowView = UIView()
  private let scrubbingLensEffectView: UIVisualEffectView
  private var slotViews: [SlotView] = []
  private var specs: [TabSpec] = []
  private(set) var selectedIndex: Int = 0
  private var highlightedIndex: Int = 0
  private var isScrubbing: Bool = false
  private var scrubContinuousSlot: CGFloat?
  private var lastScrubX: CGFloat?
  private var lastScrubTimestamp: TimeInterval = 0
  private var scrubVelocityX: CGFloat = 0
  private let selectionFeedback = UISelectionFeedbackGenerator()

  var onSelect: ((Int) -> Void)?

  override init(frame: CGRect) {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = true
      effectView = UIVisualEffectView(effect: glass)

      let lensGlass = UIGlassEffect(style: .clear)
      lensGlass.isInteractive = true
      scrubbingLensEffectView = UIVisualEffectView(effect: lensGlass)
    } else {
      effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
      scrubbingLensEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    }
    #else
    effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    scrubbingLensEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    #endif
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false
    isMultipleTouchEnabled = false
    isExclusiveTouch = true
    overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle

    effectView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    effectView.backgroundColor = .clear
    effectView.isUserInteractionEnabled = false
    effectView.translatesAutoresizingMaskIntoConstraints = false
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      effectView.cornerConfiguration = .capsule()
    } else {
      effectView.layer.cornerCurve = .continuous
      effectView.clipsToBounds = true
    }
    #else
    effectView.layer.cornerCurve = .continuous
    effectView.clipsToBounds = true
    #endif
    addSubview(effectView)

    selectionLensView.backgroundColor = UIColor.white.withAlphaComponent(0.16)
    selectionLensView.layer.cornerCurve = .continuous
    selectionLensView.layer.borderWidth = 0.5
    selectionLensView.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
    selectionLensView.isUserInteractionEnabled = false
    effectView.contentView.addSubview(selectionLensView)

    slotsStack.axis = .horizontal
    slotsStack.alignment = .fill
    slotsStack.distribution = .fillEqually
    slotsStack.spacing = 0.0
    slotsStack.isUserInteractionEnabled = false
    slotsStack.translatesAutoresizingMaskIntoConstraints = false
    effectView.contentView.addSubview(slotsStack)

    // Elevated native iOS 26 refractive Liquid Glass scrubbing bubble sitting
    // above the tab icons & outer capsule so holding and dragging physically
    // lifts and refracts the icons beneath the finger like system UITabBar.
    scrubbingLensShadowView.backgroundColor = .clear
    scrubbingLensShadowView.isOpaque = false
    scrubbingLensShadowView.clipsToBounds = false
    scrubbingLensShadowView.isUserInteractionEnabled = false
    scrubbingLensShadowView.alpha = 0.0
    scrubbingLensShadowView.layer.shadowColor = UIColor.black.cgColor
    scrubbingLensShadowView.layer.shadowOpacity = 0.18
    scrubbingLensShadowView.layer.shadowRadius = 14.0
    scrubbingLensShadowView.layer.shadowOffset = CGSize(width: 0, height: 5)
    addSubview(scrubbingLensShadowView)

    scrubbingLensEffectView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    scrubbingLensEffectView.backgroundColor = .clear
    scrubbingLensEffectView.isUserInteractionEnabled = false
    scrubbingLensEffectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      scrubbingLensEffectView.cornerConfiguration = .capsule()
    } else {
      scrubbingLensEffectView.layer.cornerCurve = .continuous
      scrubbingLensEffectView.clipsToBounds = true
      scrubbingLensEffectView.layer.borderWidth = 0.85
    }
    #else
    scrubbingLensEffectView.layer.cornerCurve = .continuous
    scrubbingLensEffectView.clipsToBounds = true
    scrubbingLensEffectView.layer.borderWidth = 0.85
    #endif
    scrubbingLensShadowView.addSubview(scrubbingLensEffectView)

    NSLayoutConstraint.activate([
      effectView.topAnchor.constraint(equalTo: topAnchor),
      effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
      effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
      effectView.trailingAnchor.constraint(equalTo: trailingAnchor),

      slotsStack.topAnchor.constraint(equalTo: effectView.contentView.topAnchor, constant: 4.0),
      slotsStack.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor, constant: -4.0),
      slotsStack.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor, constant: 4.0),
      slotsStack.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor, constant: -4.0),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      refreshAppearance()
    }
  }

  func setItems(_ items: [TabSpec]) {
    specs = items
    for old in slotViews {
      slotsStack.removeArrangedSubview(old)
      old.removeFromSuperview()
    }
    slotViews.removeAll()
    for spec in items {
      let slot = SlotView()
      slot.titleLabel.text = spec.label
      slot.accessibilityLabel = spec.label
      slotsStack.addArrangedSubview(slot)
      slotViews.append(slot)
    }
    if selectedIndex >= items.count {
      selectedIndex = max(0, items.count - 1)
    }
    highlightedIndex = selectedIndex
    applySlotAppearances(activeIndex: selectedIndex)
    setNeedsLayout()
  }

  func setSelectedIndex(_ index: Int, animated: Bool) {
    guard index >= 0, index < specs.count else { return }
    let changed = selectedIndex != index
    selectedIndex = index
    if !isScrubbing {
      highlightedIndex = index
      applySlotAppearances(activeIndex: index)
      positionLens(slotPosition: CGFloat(index), animated: animated && changed, lifted: false)
      if animated && changed && index < slotViews.count {
        slotViews[index].playSelectedMotion()
      }
    }
  }

  private func applySlotAppearances(activeIndex: Int) {
    let dark = MarcoLiquidGlassSupport.isEffectiveDark(for: self)
    let activeLabelColor: UIColor = dark
      ? UIColor(red: 0.36, green: 0.72, blue: 1.0, alpha: 1.0)
      : UIColor.systemBlue
    let inactiveLabelColor: UIColor = dark
      ? UIColor.white.withAlphaComponent(0.70)
      : UIColor(red: 0.17, green: 0.19, blue: 0.23, alpha: 0.76)
    selectionLensView.layer.borderColor = (dark
      ? UIColor(red: 0.55, green: 0.80, blue: 1.0, alpha: 0.28)
      : UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.16)).cgColor
    scrubbingLensShadowView.layer.shadowOpacity = dark ? 0.34 : 0.16
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      // Native UIGlassEffect draws its own optical specular border.
    } else {
      scrubbingLensEffectView.layer.borderColor = (dark
        ? UIColor.white.withAlphaComponent(0.32)
        : UIColor.white.withAlphaComponent(0.75)).cgColor
    }
    #else
    scrubbingLensEffectView.layer.borderColor = (dark
      ? UIColor.white.withAlphaComponent(0.32)
      : UIColor.white.withAlphaComponent(0.75)).cgColor
    #endif
    for (idx, slot) in slotViews.enumerated() where idx < specs.count {
      let spec = specs[idx]
      let isSelected = idx == activeIndex
      let symName = isSelected ? spec.selectedSymbol : spec.symbol
      slot.iconView.configure(
        kind: spec.kind,
        selected: isSelected,
        dark: dark,
        fallbackSymbol: symName
      )
      slot.titleLabel.textColor = isSelected ? activeLabelColor : inactiveLabelColor
      slot.titleLabel.font = UIFont.systemFont(ofSize: 10.5, weight: isSelected ? .semibold : .medium)
      slot.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
    }
  }

  func refreshAppearance() {
    overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    effectView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    scrubbingLensEffectView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    applySlotAppearances(activeIndex: isScrubbing ? highlightedIndex : selectedIndex)
    let slotPos = scrubContinuousSlot ?? CGFloat(selectedIndex)
    positionLens(slotPosition: slotPos, animated: false, lifted: isScrubbing)
  }

  private func lensMetrics(for slotPosition: CGFloat) -> (bounds: CGRect, center: CGPoint)? {
    let count = specs.count
    guard count > 0, bounds.width > 8.0, bounds.height > 8.0 else { return nil }
    let inset: CGFloat = 4.0
    let innerW = bounds.width - inset * 2.0
    let slotW = innerW / CGFloat(count)
    let lensH = bounds.height - inset * 2.0
    let clampedPos = max(0.0, min(slotPosition, CGFloat(count - 1)))
    let centerX = inset + slotW * (clampedPos + 0.5)
    let centerY = bounds.height * 0.5
    return (CGRect(x: 0, y: 0, width: slotW, height: lensH), CGPoint(x: centerX, y: centerY))
  }

  private func positionLens(slotPosition: CGFloat, animated: Bool, lifted: Bool) {
    guard let metrics = lensMetrics(for: slotPosition) else { return }
    selectionLensView.layer.cornerRadius = metrics.bounds.height * 0.5
    let liftedBounds = CGRect(
      x: 0,
      y: 0,
      width: metrics.bounds.width + 10.0,
      height: bounds.height + 6.0
    )
    let speedNorm = min(abs(scrubVelocityX) / 1400.0, 1.0)
    let stretchX: CGFloat = lifted ? (1.03 + speedNorm * 0.08) : 0.90
    let stretchY: CGFloat = lifted ? (1.04 - speedNorm * 0.03) : 0.88
    let apply = {
      self.selectionLensView.bounds = metrics.bounds
      self.selectionLensView.center = metrics.center
      self.selectionLensView.transform = .identity
      let dark = MarcoLiquidGlassSupport.isEffectiveDark(for: self)
      self.selectionLensView.backgroundColor = dark
        ? UIColor(red: 0.22, green: 0.58, blue: 1.0, alpha: 0.22)
        : UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.12)
      self.selectionLensView.alpha = lifted ? 0.0 : 1.0

      self.scrubbingLensShadowView.bounds = liftedBounds
      self.scrubbingLensShadowView.center = metrics.center
      self.scrubbingLensShadowView.layer.shadowPath = UIBezierPath(
        roundedRect: liftedBounds,
        cornerRadius: liftedBounds.height * 0.5
      ).cgPath
      self.scrubbingLensEffectView.frame = liftedBounds
      #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        // Handled natively via cornerConfiguration = .capsule().
      } else {
        self.scrubbingLensEffectView.layer.cornerRadius = liftedBounds.height * 0.5
      }
      #else
      self.scrubbingLensEffectView.layer.cornerRadius = liftedBounds.height * 0.5
      #endif
      self.scrubbingLensShadowView.transform = CGAffineTransform(scaleX: stretchX, y: stretchY)
      self.scrubbingLensShadowView.alpha = lifted ? 1.0 : 0.0
    }
    if animated {
      UIView.animate(
        withDuration: lifted ? 0.20 : 0.34,
        delay: 0,
        usingSpringWithDamping: lifted ? 0.78 : 0.76,
        initialSpringVelocity: 0.7,
        options: [.beginFromCurrentState, .allowUserInteraction],
        animations: apply,
        completion: nil
      )
    } else {
      apply()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      // Handled natively via cornerConfiguration = .capsule().
    } else {
      effectView.layer.cornerRadius = bounds.height * 0.5
    }
    #else
    effectView.layer.cornerRadius = bounds.height * 0.5
    #endif
    let slotPos = scrubContinuousSlot ?? CGFloat(selectedIndex)
    positionLens(slotPosition: slotPos, animated: false, lifted: isScrubbing)
  }

  private func indexForX(_ x: CGFloat) -> (discrete: Int, continuous: CGFloat) {
    let count = max(specs.count, 1)
    let inset: CGFloat = 4.0
    let innerW = max(bounds.width - inset * 2.0, 1.0)
    let slotW = innerW / CGFloat(count)
    let relative = x - inset
    let discrete = max(0, min(Int(floor(relative / slotW)), count - 1))
    let continuous = max(0.0, min((relative - slotW * 0.5) / slotW, CGFloat(count - 1)))
    return (discrete, continuous)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesBegan(touches, with: event)
    guard let touch = touches.first, !specs.isEmpty else { return }
    selectionFeedback.prepare()
    let pt = touch.location(in: self)
    let (idx, _) = indexForX(pt.x)
    let prevHighlighted = highlightedIndex
    isScrubbing = true
    highlightedIndex = idx
    scrubContinuousSlot = CGFloat(idx)
    lastScrubX = pt.x
    lastScrubTimestamp = touch.timestamp
    scrubVelocityX = 0
    applySlotAppearances(activeIndex: idx)
    positionLens(slotPosition: CGFloat(idx), animated: true, lifted: true)
    if idx != prevHighlighted && idx < slotViews.count {
      slotViews[idx].playSelectedMotion()
    }
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesMoved(touches, with: event)
    guard isScrubbing, let touch = touches.first, !specs.isEmpty else { return }
    let pt = touch.location(in: self)
    if let prevX = lastScrubX {
      let dt = max(touch.timestamp - lastScrubTimestamp, 0.008)
      let instantV = (pt.x - prevX) / CGFloat(dt)
      scrubVelocityX = scrubVelocityX * 0.6 + instantV * 0.4
    }
    lastScrubX = pt.x
    lastScrubTimestamp = touch.timestamp
    let (idx, continuous) = indexForX(pt.x)
    scrubContinuousSlot = continuous
    if idx != highlightedIndex {
      highlightedIndex = idx
      selectionFeedback.selectionChanged()
      applySlotAppearances(activeIndex: idx)
      if idx < slotViews.count {
        slotViews[idx].playSelectedMotion()
      }
    }
    positionLens(slotPosition: continuous, animated: false, lifted: true)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesEnded(touches, with: event)
    guard isScrubbing else { return }
    let target = highlightedIndex
    isScrubbing = false
    scrubContinuousSlot = nil
    lastScrubX = nil
    scrubVelocityX = 0
    let changed = target != selectedIndex
    selectedIndex = target
    applySlotAppearances(activeIndex: target)
    positionLens(slotPosition: CGFloat(target), animated: true, lifted: false)
    if changed {
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    } else if target < slotViews.count {
      // Re-tapping the already-selected tab still gives a delightful micro-pop!
      slotViews[target].playSelectedMotion()
    }
    onSelect?(target)
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesCancelled(touches, with: event)
    guard isScrubbing else { return }
    isScrubbing = false
    scrubContinuousSlot = nil
    lastScrubX = nil
    scrubVelocityX = 0
    highlightedIndex = selectedIndex
    applySlotAppearances(activeIndex: selectedIndex)
    positionLens(slotPosition: CGFloat(selectedIndex), animated: true, lifted: false)
  }
}

private final class MarcoIos27PassthroughChromeView: UIView {
  weak var chromeView: UIView?
  weak var glassContainerView: UIVisualEffectView?

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
    guard let hit = super.hitTest(point, with: event) else { return nil }
    if hit === self || hit === chromeView || hit === glassContainerView || hit === glassContainerView?.contentView {
      return nil
    }
    return hit
  }
}

private final class MarcoIos27DockChromeView: UIView, UITabBarDelegate {
  private let isRootHost: Bool
  private let glassContainerView: UIVisualEffectView?
  private let fallbackContainerView = UIView()
  private let nativeTabBar = UITabBar(frame: .zero)
  private let legacyTabCapsule = MarcoNativeLiquidTabCapsuleView(frame: .zero)
  private let searchButton = UIButton(type: .system)
  private let logoButton = UIButton(type: .system)

  private var rawItemDicts: [[String: Any]] = []
  private var tabSpecs: [MarcoNativeLiquidTabCapsuleView.TabSpec] = []
  private(set) var selectedIndex: Int = 0
  private(set) var isMinimized: Bool = false
  private(set) var isChromeVisible: Bool = true
  private var minimizeProgress: CGFloat = 0.0
  var showSearchButton: Bool = true {
    didSet {
      updateVisibilityState()
      setNeedsLayout()
    }
  }
  var adaptiveTopOnWide: Bool = true {
    didSet { setNeedsLayout() }
  }

  var onSelectTab: ((Int) -> Void)?
  var onSearchTapped: (() -> Void)?
  var onScrollToTopTapped: (() -> Void)?

  private var usesNativeGlass26: Bool {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      return !UIAccessibility.isReduceTransparencyEnabled
    }
    #endif
    return false
  }

  init(isRootHost: Bool, frame: CGRect = .zero) {
    self.isRootHost = isRootHost
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      let containerEffect = UIGlassContainerEffect()
      containerEffect.spacing = 10.0
      self.glassContainerView = UIVisualEffectView(effect: containerEffect)
    } else {
      self.glassContainerView = nil
    }
    #else
    self.glassContainerView = nil
    #endif
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false
    insetsLayoutMarginsFromSafeArea = false
    overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle

    let contentParent: UIView
    if let glassContainer = glassContainerView {
      glassContainer.backgroundColor = .clear
      glassContainer.isOpaque = false
      glassContainer.clipsToBounds = false
      glassContainer.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
      addSubview(glassContainer)
      contentParent = glassContainer.contentView
    } else {
      fallbackContainerView.backgroundColor = .clear
      fallbackContainerView.isOpaque = false
      fallbackContainerView.clipsToBounds = false
      addSubview(fallbackContainerView)
      contentParent = fallbackContainerView
    }

    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      nativeTabBar.delegate = self
      nativeTabBar.isTranslucent = true
      nativeTabBar.itemPositioning = .fill
      nativeTabBar.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
      nativeTabBar.cornerConfiguration = .capsule()
      contentParent.addSubview(nativeTabBar)
    } else {
      contentParent.addSubview(legacyTabCapsule)
    }
    #else
    contentParent.addSubview(legacyTabCapsule)
    #endif

    legacyTabCapsule.onSelect = { [weak self] idx in
      guard let self = self else { return }
      self.selectedIndex = idx
      self.rebuildLogoMenu()
      self.onSelectTab?(idx)
    }

    configureGlassCircleButton(
      searchButton,
      image: UIImage(
        systemName: "magnifyingglass",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 20.5, weight: .semibold)
      ),
      accessibilityLabel: "搜索"
    )
    searchButton.addTarget(self, action: #selector(handleSearchTap), for: .touchUpInside)
    contentParent.addSubview(searchButton)

    configureGlassCircleButton(
      logoButton,
      image: MarcoLiquidGlassSupport.brandLogoImage,
      accessibilityLabel: "快捷导航"
    )
    logoButton.showsMenuAsPrimaryAction = true
    logoButton.alpha = 0.0
    logoButton.isUserInteractionEnabled = false
    logoButton.transform = CGAffineTransform(scaleX: 0.55, y: 0.55)
    contentParent.addSubview(logoButton)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppearanceChanged),
      name: MarcoLiquidGlassSupport.appearanceChangedNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleSceneActivationChanged),
      name: MarcoLiquidGlassSupport.sceneActivationChangedNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var containerViewForHitTest: UIVisualEffectView? {
    return glassContainerView
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
    guard let hit = super.hitTest(point, with: event) else { return nil }
    if hit === self || hit === fallbackContainerView || hit === glassContainerView || hit === glassContainerView?.contentView {
      return nil
    }
    return hit
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      handleAppearanceChanged()
    }
  }

  private func configureGlassCircleButton(
    _ button: UIButton,
    image: UIImage?,
    accessibilityLabel: String
  ) {
    let fg = MarcoLiquidGlassSupport.adaptiveGlassForeground(for: self)
    button.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    button.accessibilityLabel = accessibilityLabel
    if #available(iOS 17.0, *) {
      button.isSymbolAnimationEnabled = true
    }
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      var cfg = UIButton.Configuration.glass()
      cfg.image = image
      cfg.baseForegroundColor = fg
      cfg.cornerStyle = .capsule
      cfg.contentInsets = .zero
      button.configuration = cfg
      button.cornerConfiguration = .capsule()
      return
    }
    #endif
    let dark = MarcoLiquidGlassSupport.isEffectiveDark(for: self)
    var cfg = UIButton.Configuration.filled()
    cfg.image = image
    cfg.baseForegroundColor = fg
    cfg.baseBackgroundColor = dark
      ? UIColor(white: 0.16, alpha: 0.88)
      : UIColor(white: 0.98, alpha: 0.92)
    cfg.cornerStyle = .capsule
    cfg.contentInsets = .zero
    button.configuration = cfg
  }

  @objc private func handleAppearanceChanged() {
    overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    glassContainerView?.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    nativeTabBar.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    legacyTabCapsule.refreshAppearance()
    configureGlassCircleButton(
      searchButton,
      image: UIImage(
        systemName: "magnifyingglass",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 20.5, weight: .semibold)
      ),
      accessibilityLabel: "搜索"
    )
    configureGlassCircleButton(
      logoButton,
      image: MarcoLiquidGlassSupport.brandLogoImage,
      accessibilityLabel: "快捷导航"
    )
  }

  @objc private func handleSceneActivationChanged() {
    let active = MarcoLiquidGlassSupport.isSceneActive
    let targetAlpha: CGFloat = isChromeVisible ? (active ? 1.0 : 0.86) : 0.0
    UIView.animate(withDuration: 0.18) {
      self.alpha = targetAlpha
    }
  }

  @objc private func handleSearchTap() {
    if #available(iOS 17.0, *) {
      searchButton.imageView?.addSymbolEffect(.bounce, options: .nonRepeating, animated: true)
    }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    onSearchTapped?()
  }

  private func updateVisibilityState() {
    searchButton.isHidden = !showSearchButton && !isMinimized
  }

  func setItems(_ rawItems: [[String: Any]]) {
    guard !rawItems.isEmpty else { return }
    rawItemDicts = rawItems
    let specs = rawItems.map { item -> MarcoNativeLiquidTabCapsuleView.TabSpec in
      let title = (item["label"] as? String) ?? ""
      let symbol = (item["symbol"] as? String) ?? "circle"
      let selectedSymbol = (item["selectedSymbol"] as? String) ?? symbol
      let kind = MarcoAnimatedTabIconView.Kind.resolve(
        kind: item["kind"] as? String,
        symbol: symbol,
        label: title
      )
      return MarcoNativeLiquidTabCapsuleView.TabSpec(
        label: title,
        symbol: symbol,
        selectedSymbol: selectedSymbol,
        kind: kind
      )
    }
    tabSpecs = specs
    legacyTabCapsule.setItems(specs)

    var barItems: [UITabBarItem] = []
    for (idx, spec) in specs.enumerated() {
      let img = UIImage(systemName: spec.symbol)
      let selImg = UIImage(systemName: spec.selectedSymbol) ?? img
      let barItem = UITabBarItem(title: spec.label, image: img, selectedImage: selImg)
      barItem.tag = idx
      barItems.append(barItem)
    }
    nativeTabBar.setItems(barItems, animated: false)
    if selectedIndex >= 0, selectedIndex < barItems.count {
      nativeTabBar.selectedItem = barItems[selectedIndex]
    }
    rebuildLogoMenu()
    setNeedsLayout()
  }

  func setSelectedIndex(_ index: Int, animated: Bool) {
    guard index >= 0, index < max(tabSpecs.count, rawItemDicts.count) else { return }
    selectedIndex = index
    legacyTabCapsule.setSelectedIndex(index, animated: animated)
    if let barItems = nativeTabBar.items, index < barItems.count {
      nativeTabBar.selectedItem = barItems[index]
    }
    rebuildLogoMenu()
  }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    let idx = item.tag
    guard idx >= 0, idx < max(tabSpecs.count, rawItemDicts.count) else { return }
    selectedIndex = idx
    legacyTabCapsule.setSelectedIndex(idx, animated: true)
    rebuildLogoMenu()
    UISelectionFeedbackGenerator().selectionChanged()
    onSelectTab?(idx)
  }

  private func activeTabView() -> UIView {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      return nativeTabBar
    }
    #endif
    return legacyTabCapsule
  }

  func updateScrollMinimizeProgress(_ rawProgress: CGFloat) {
    let p = max(0.0, min(rawProgress, 1.0))
    minimizeProgress = p
    let minimizedTarget = p >= 0.5
    isMinimized = minimizedTarget
    let tabView = activeTabView()
    let targetCenterX = logoButton.center.x
    let tabShift = (targetCenterX - tabView.center.x) * 0.42 * p
    let tabScale = 1.0 - 0.55 * p
    let searchScale = 1.0 - 0.55 * p
    let logoScale = 0.55 + 0.45 * p

    #if compiler(>=6.2)
    if #available(iOS 26.0, *), let glassEffect = glassContainerView?.effect as? UIGlassContainerEffect {
      glassEffect.spacing = max(0.0, 10.0 * (1.0 - p))
    }
    #endif

    tabView.alpha = max(0.0, 1.0 - p * 1.15)
    tabView.transform = CGAffineTransform(translationX: tabShift, y: 0).scaledBy(x: tabScale, y: tabScale)
    searchButton.alpha = showSearchButton ? max(0.0, 1.0 - p * 1.15) : 0.0
    searchButton.transform = CGAffineTransform(scaleX: searchScale, y: searchScale)
    logoButton.alpha = max(0.0, (p - 0.2) / 0.8)
    logoButton.transform = CGAffineTransform(scaleX: logoScale, y: logoScale)

    tabView.isUserInteractionEnabled = !minimizedTarget
    searchButton.isUserInteractionEnabled = !minimizedTarget && showSearchButton
    logoButton.isUserInteractionEnabled = minimizedTarget
  }

  func setMinimized(_ minimized: Bool, animated: Bool) {
    guard minimized != isMinimized || (minimized ? minimizeProgress < 0.99 : minimizeProgress > 0.01) else {
      return
    }
    isMinimized = minimized
    minimizeProgress = minimized ? 1.0 : 0.0
    let tabView = activeTabView()
    let targetCenterX = logoButton.center.x
    let tabShift = targetCenterX - tabView.center.x

    let apply = {
      #if compiler(>=6.2)
      if #available(iOS 26.0, *), let glassEffect = self.glassContainerView?.effect as? UIGlassContainerEffect {
        glassEffect.spacing = minimized ? 0.0 : 10.0
      }
      #endif
      if minimized {
        tabView.alpha = 0.0
        tabView.transform = CGAffineTransform(translationX: tabShift * 0.42, y: 0).scaledBy(x: 0.45, y: 0.45)
        self.searchButton.alpha = 0.0
        self.searchButton.transform = CGAffineTransform(scaleX: 0.45, y: 0.45)
        self.logoButton.alpha = 1.0
        self.logoButton.transform = .identity
      } else {
        tabView.alpha = 1.0
        tabView.transform = .identity
        self.searchButton.alpha = self.showSearchButton ? 1.0 : 0.0
        self.searchButton.transform = .identity
        self.logoButton.alpha = 0.0
        self.logoButton.transform = CGAffineTransform(scaleX: 0.55, y: 0.55)
      }
    }

    tabView.isUserInteractionEnabled = !minimized
    searchButton.isUserInteractionEnabled = !minimized && showSearchButton
    logoButton.isUserInteractionEnabled = minimized

    if animated {
      MarcoLiquidGlassSupport.animateSpring(duration: 0.38, bounce: 0.16, animations: apply)
    } else {
      apply()
    }
  }

  func setRootDockVisible(_ visible: Bool, animated: Bool) {
    isChromeVisible = visible
    isUserInteractionEnabled = visible
    let isTopWide = isRootHost && adaptiveTopOnWide && (bounds.width >= 600.0 || bounds.width > bounds.height)
    let hiddenOffsetY: CGFloat = isTopWide ? -96.0 : 120.0
    let targetTransform = visible ? CGAffineTransform.identity : CGAffineTransform(translationX: 0.0, y: hiddenOffsetY)
    let targetAlpha: CGFloat = visible ? (MarcoLiquidGlassSupport.isSceneActive ? 1.0 : 0.86) : 0.0

    let apply = {
      let host: UIView = self.glassContainerView ?? self.fallbackContainerView
      host.transform = targetTransform
      self.alpha = targetAlpha
    }
    if animated {
      MarcoLiquidGlassSupport.animateSpring(duration: 0.38, bounce: 0.16, animations: apply)
    } else {
      apply()
    }
  }

  private func rebuildLogoMenu() {
    var sections: [UIMenuElement] = []

    if showSearchButton {
      let searchAction = UIAction(
        title: "搜索影片",
        image: UIImage(systemName: "magnifyingglass")
      ) { [weak self] _ in
        self?.handleSearchTap()
      }
      sections.append(UIMenu(title: "", options: .displayInline, children: [searchAction]))
    }

    var navActions: [UIAction] = []
    for (idx, item) in rawItemDicts.enumerated() {
      let title = (item["label"] as? String) ?? ""
      let isSelected = idx == selectedIndex
      let symbol = isSelected
        ? ((item["selectedSymbol"] as? String) ?? (item["symbol"] as? String) ?? "circle")
        : ((item["symbol"] as? String) ?? "circle")
      let action = UIAction(
        title: title,
        image: UIImage(systemName: symbol),
        state: isSelected ? .on : .off
      ) { [weak self] _ in
        guard let self = self else { return }
        self.setSelectedIndex(idx, animated: true)
        self.onSelectTab?(idx)
      }
      navActions.append(action)
    }
    if !navActions.isEmpty {
      sections.append(UIMenu(title: "", options: .displayInline, children: navActions))
    }

    let topAction = UIAction(
      title: "回到顶部",
      image: UIImage(systemName: "arrow.up.to.line")
    ) { [weak self] _ in
      self?.onScrollToTopTapped?()
    }
    sections.append(UIMenu(title: "", options: .displayInline, children: [topAction]))

    logoButton.menu = UIMenu(title: "", children: sections)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let totalW = bounds.width
    let totalH = bounds.height
    guard totalW > 0, totalH > 0 else { return }

    let containerTarget: UIView = glassContainerView ?? fallbackContainerView
    let safeInsets = window?.safeAreaInsets ?? safeAreaInsets

    // Determine whether we are embedded inside a 76pt PlatformView slice or full-screen root host.
    let isEmbeddedSlice = !isRootHost || totalH <= 140.0
    let isWideTopLayout = !isEmbeddedSlice && adaptiveTopOnWide && (totalW >= 600.0 || totalW > totalH)

    let chromeBounds: CGRect
    if isEmbeddedSlice {
      chromeBounds = bounds
    } else if isWideTopLayout {
      let barH: CGFloat = 54.0
      let topY = max(safeInsets.top, 10.0) + 6.0
      chromeBounds = CGRect(x: 0.0, y: topY, width: totalW, height: barH)
    } else {
      let barH: CGFloat = 72.0
      let bottomY = totalH - max(safeInsets.bottom, 8.0) - barH
      chromeBounds = CGRect(x: 0.0, y: max(0.0, bottomY), width: totalW, height: barH)
    }

    containerTarget.bounds = CGRect(x: 0.0, y: 0.0, width: chromeBounds.width, height: chromeBounds.height)
    containerTarget.center = CGPoint(x: chromeBounds.midX, y: chromeBounds.midY)

    let cw = chromeBounds.width
    let ch = chromeBounds.height
    let isCompactSplit = cw < 360.0
    let outerMargin: CGFloat = isCompactSplit ? 10.0 : 16.0
    let gap: CGFloat = isCompactSplit ? 8.0 : 10.0
    let dockSize: CGFloat = min(isWideTopLayout ? 52.0 : (cw < 340.0 ? 56.0 : 62.0), ch)

    let tabView = activeTabView()
    if isMinimized && cw < 150.0 {
      logoButton.bounds = CGRect(x: 0, y: 0, width: dockSize, height: dockSize)
      logoButton.center = CGPoint(x: cw - outerMargin - dockSize * 0.5, y: ch * 0.5)
      containerTarget.bringSubviewToFront(logoButton)
      return
    }

    let maxCap: CGFloat = isWideTopLayout ? 520.0 : (cw >= 600.0 ? 468.0 : 440.0)
    let maxRowWidth: CGFloat = min(cw, maxCap)
    let rowX = (cw - maxRowWidth) * 0.5
    let centerY = ch * 0.5

    let rightCenterX = rowX + maxRowWidth - outerMargin - dockSize * 0.5
    logoButton.bounds = CGRect(x: 0, y: 0, width: dockSize, height: dockSize)
    logoButton.center = CGPoint(x: rightCenterX, y: centerY)

    if showSearchButton {
      searchButton.bounds = CGRect(x: 0, y: 0, width: dockSize, height: dockSize)
      searchButton.center = CGPoint(x: rightCenterX, y: centerY)

      let tabX = rowX + outerMargin
      let availTabW = (rightCenterX - dockSize * 0.5 - gap) - tabX
      let tabW = max(availTabW, min(180.0, max(availTabW, 132.0)))
      tabView.bounds = CGRect(x: 0, y: 0, width: tabW, height: dockSize)
      tabView.center = CGPoint(x: tabX + tabW * 0.5, y: centerY)
    } else {
      let tabX = rowX + outerMargin
      let availTabW = maxRowWidth - outerMargin * 2.0
      let tabW = max(availTabW, min(180.0, max(availTabW, 132.0)))
      tabView.bounds = CGRect(x: 0, y: 0, width: tabW, height: dockSize)
      tabView.center = CGPoint(x: tabX + tabW * 0.5, y: centerY)
    }

    let contentParent = glassContainerView?.contentView ?? fallbackContainerView
    contentParent.bringSubviewToFront(searchButton)
    contentParent.bringSubviewToFront(logoButton)
  }
}

private final class MarcoIos27RootTabChromeController: NSObject {
  static let shared = MarcoIos27RootTabChromeController()

  private let overlayView = MarcoIos27PassthroughChromeView(frame: .zero)
  private let chromeView = MarcoIos27DockChromeView(isRootHost: true, frame: .zero)
  private var observers: [NSObjectProtocol] = []
  private weak var attachedHostView: UIView?

  private override init() {
    super.init()
    overlayView.backgroundColor = .clear
    overlayView.isOpaque = false
    overlayView.clipsToBounds = false
    overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    overlayView.chromeView = chromeView
    overlayView.glassContainerView = chromeView.containerViewForHitTest

    chromeView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    overlayView.addSubview(chromeView)

    chromeView.onSelectTab = { idx in
      MarcoLiquidGlassSupport.bridgeChannel?.invokeMethod("rootTabSelected", arguments: idx)
    }
    chromeView.onSearchTapped = {
      MarcoLiquidGlassSupport.bridgeChannel?.invokeMethod("rootTabSearchTapped", arguments: nil)
    }
    chromeView.onScrollToTopTapped = {
      MarcoLiquidGlassSupport.bridgeChannel?.invokeMethod("rootTabScrollToTop", arguments: nil)
    }

    observers.append(
      NotificationCenter.default.addObserver(
        forName: MarcoLiquidGlassSupport.windowGeometryChangedNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.syncOverlayFrame()
      }
    )
  }

  deinit {
    for obs in observers {
      NotificationCenter.default.removeObserver(obs)
    }
  }

  private func attachToRootIfNeeded() {
    guard let rootVC = MarcoLiquidGlassSupport.activeWindow()?.rootViewController,
          let rootView = rootVC.view else {
      return
    }
    if attachedHostView !== rootView || overlayView.superview !== rootView {
      overlayView.removeFromSuperview()
      overlayView.frame = rootView.bounds
      chromeView.frame = overlayView.bounds
      rootView.addSubview(overlayView)
      attachedHostView = rootView
    }
    rootView.bringSubviewToFront(overlayView)
  }

  private func syncOverlayFrame() {
    guard let rootView = attachedHostView ?? MarcoLiquidGlassSupport.activeWindow()?.rootViewController?.view else {
      return
    }
    overlayView.frame = rootView.bounds
    chromeView.frame = overlayView.bounds
    chromeView.setNeedsLayout()
    rootView.bringSubviewToFront(overlayView)
  }

  func configure(args: [String: Any]) {
    attachToRootIfNeeded()
    if let showSearch = args["showSearch"] as? Bool {
      chromeView.showSearchButton = showSearch
    }
    if let adaptiveTop = args["adaptiveTopOnWide"] as? Bool {
      chromeView.adaptiveTopOnWide = adaptiveTop
    }
    if let items = args["items"] as? [[String: Any]], !items.isEmpty {
      chromeView.setItems(items)
    }
    if let selectedIndex = args["selectedIndex"] as? Int {
      chromeView.setSelectedIndex(selectedIndex, animated: false)
    }
    if let minimized = args["minimized"] as? Bool {
      chromeView.setMinimized(minimized, animated: false)
    }
    if let visible = args["visible"] as? Bool {
      chromeView.setRootDockVisible(visible, animated: false)
    }
    syncOverlayFrame()
  }

  func setSelectedIndex(_ index: Int, animated: Bool) {
    attachToRootIfNeeded()
    chromeView.setSelectedIndex(index, animated: animated)
  }

  func setMinimized(_ minimized: Bool, animated: Bool) {
    attachToRootIfNeeded()
    chromeView.setMinimized(minimized, animated: animated)
  }

  func updateScrollMinimizeProgress(_ progress: CGFloat) {
    attachToRootIfNeeded()
    chromeView.updateScrollMinimizeProgress(progress)
  }

  func setRootDockVisible(_ visible: Bool, animated: Bool) {
    attachToRootIfNeeded()
    chromeView.setRootDockVisible(visible, animated: animated)
  }
}

private final class MarcoNativeDockPlatformView: NSObject, FlutterPlatformView {
  private let container: MarcoIos27DockChromeView
  private let channel: FlutterMethodChannel

  init(
    frame: CGRect,
    viewId: Int64,
    arguments args: [String: Any]?,
    messenger: FlutterBinaryMessenger
  ) {
    let initialFrame = MarcoLiquidGlassSupport.resolvedInitialFrame(
      frame,
      args: args,
      defaultWidth: MarcoLiquidGlassSupport.activeWindowBounds().width,
      defaultHeight: 76.0
    )
    self.container = MarcoIos27DockChromeView(isRootHost: false, frame: initialFrame)
    self.channel = FlutterMethodChannel(
      name: "marco_movie/ios26_dock_\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    container.onSelectTab = { [weak self] idx in
      self?.channel.invokeMethod("onSelect", arguments: idx)
    }
    container.onSearchTapped = { [weak self] in
      self?.channel.invokeMethod("onSearch", arguments: nil)
    }
    container.onScrollToTopTapped = { [weak self] in
      self?.channel.invokeMethod("onScrollToTop", arguments: nil)
    }

    if let args = args {
      MarcoLiquidGlassSupport.withoutAnimations {
        self.applyState(args, animated: false)
        self.container.layoutIfNeeded()
      }
    }

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      DispatchQueue.main.async {
        switch call.method {
        case "update":
          if let args = call.arguments as? [String: Any] {
            self.applyState(args, animated: true)
          }
          result(nil)
        case "setSelectedIndex":
          if let idx = call.arguments as? Int {
            self.container.setSelectedIndex(idx, animated: true)
          }
          result(nil)
        case "setCollapsed":
          if let collapsed = call.arguments as? Bool {
            self.container.setMinimized(collapsed, animated: true)
          }
          result(nil)
        case "setHidden":
          if let hidden = call.arguments as? Bool {
            self.container.setRootDockVisible(!hidden, animated: true)
          }
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView {
    return container
  }

  private func applyState(_ args: [String: Any], animated: Bool) {
    if let showSearch = args["showSearch"] as? Bool {
      container.showSearchButton = showSearch
    }
    if let hidden = args["hidden"] as? Bool {
      container.setRootDockVisible(!hidden, animated: animated)
    }
    if let rawItems = args["items"] as? [[String: Any]], !rawItems.isEmpty {
      container.setItems(rawItems)
    }
    if let selectedIndex = args["selectedIndex"] as? Int {
      container.setSelectedIndex(selectedIndex, animated: animated)
    }
    if let collapsed = args["collapsed"] as? Bool {
      container.setMinimized(collapsed, animated: animated)
    }
    container.setNeedsLayout()
  }
}

// MARK: - 2. Native iOS 26 Liquid Glass Button (Circle Icon or Capsule, Optional Native UIMenu)

private final class MarcoNativeGlassButtonFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return MarcoNativeGlassButtonPlatformView(
      frame: frame,
      viewId: viewId,
      arguments: args as? [String: Any],
      messenger: messenger
    )
  }
}

private final class MarcoNativeGlassButtonControl: UIView {
  private let button = UIButton(type: .system)
  private let fallbackBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
  private let trailingAccessoryView = UIImageView()
  private var sceneObserver: NSObjectProtocol?

  var onTap: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false
    overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle

    var useFallbackBackdrop = true
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      useFallbackBackdrop = false
    }
    #endif

    if useFallbackBackdrop {
      fallbackBlurView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
      fallbackBlurView.isUserInteractionEnabled = false
      fallbackBlurView.layer.cornerCurve = .continuous
      fallbackBlurView.clipsToBounds = true
      fallbackBlurView.translatesAutoresizingMaskIntoConstraints = false
      addSubview(fallbackBlurView)
      NSLayoutConstraint.activate([
        fallbackBlurView.topAnchor.constraint(equalTo: topAnchor),
        fallbackBlurView.bottomAnchor.constraint(equalTo: bottomAnchor),
        fallbackBlurView.leadingAnchor.constraint(equalTo: leadingAnchor),
        fallbackBlurView.trailingAnchor.constraint(equalTo: trailingAnchor),
      ])
    }

    button.translatesAutoresizingMaskIntoConstraints = false
    button.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    if #available(iOS 17.0, *) {
      button.isSymbolAnimationEnabled = true
    }
    button.addTarget(self, action: #selector(handleButtonTap), for: .touchUpInside)
    addSubview(button)

    trailingAccessoryView.contentMode = .scaleAspectFit
    trailingAccessoryView.isUserInteractionEnabled = false
    trailingAccessoryView.isHidden = true
    trailingAccessoryView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(trailingAccessoryView)

    NSLayoutConstraint.activate([
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      trailingAccessoryView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10.0),
      trailingAccessoryView.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    sceneObserver = NotificationCenter.default.addObserver(
      forName: MarcoLiquidGlassSupport.sceneActivationChangedNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      UIView.animate(withDuration: 0.18) {
        self.alpha = MarcoLiquidGlassSupport.isSceneActive ? 1.0 : 0.88
      }
    }
  }

  deinit {
    if let obs = sceneObserver {
      NotificationCenter.default.removeObserver(obs)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if fallbackBlurView.superview != nil {
      fallbackBlurView.layer.cornerRadius = bounds.height * 0.5
    }
  }

  @objc private func handleButtonTap() {
    if #available(iOS 17.0, *) {
      button.imageView?.addSymbolEffect(.bounce, options: .nonRepeating, animated: true)
    }
    onTap?()
  }

  func configure(
    isCapsule: Bool,
    label: String,
    symbol: String?,
    trailingSymbol: String?,
    foregroundColor: UIColor,
    tintColor: UIColor?,
    prominent: Bool,
    symbolSize: CGFloat,
    menu: UIMenu?,
    accessibilityLabel: String,
    forceDark: Bool
  ) {
    MarcoLiquidGlassSupport.withoutAnimations {
      let targetStyle: UIUserInterfaceStyle = forceDark ? .dark : MarcoLiquidGlassSupport.interfaceStyle
      self.tag = forceDark ? 99001 : 0
      self.overrideUserInterfaceStyle = targetStyle
      self.button.overrideUserInterfaceStyle = targetStyle
      self.fallbackBlurView.overrideUserInterfaceStyle = targetStyle
      self.accessibilityLabel = accessibilityLabel
      self.button.accessibilityLabel = accessibilityLabel

      let symCfg = UIImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold)
      let leadingImg = symbol.flatMap { UIImage(systemName: $0, withConfiguration: symCfg) }
      let hasTrailing = isCapsule && !(trailingSymbol?.isEmpty ?? true)

      if hasTrailing, let trailing = trailingSymbol {
        let trailCfg = UIImage.SymbolConfiguration(pointSize: max(symbolSize - 3.0, 11.0), weight: .semibold)
        self.trailingAccessoryView.image = UIImage(systemName: trailing, withConfiguration: trailCfg)
        self.trailingAccessoryView.tintColor = foregroundColor.withAlphaComponent(0.82)
        self.trailingAccessoryView.isHidden = false
      } else {
        self.trailingAccessoryView.isHidden = true
      }

      var titleAttr: AttributedString?
      if isCapsule && !label.isEmpty {
        var attr = AttributedString(label)
        attr.font = UIFont.systemFont(ofSize: 13.0, weight: .semibold)
        titleAttr = attr
      }

      let useProminent = prominent || tintColor != nil

      #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        var cfg = useProminent ? UIButton.Configuration.prominentGlass() : UIButton.Configuration.glass()
        cfg.image = leadingImg
        cfg.attributedTitle = titleAttr
        cfg.baseForegroundColor = foregroundColor
        if let tint = tintColor {
          cfg.baseBackgroundColor = tint
        } else if forceDark {
          cfg.baseBackgroundColor = UIColor(white: 0.10, alpha: 0.35)
        }
        cfg.imagePadding = isCapsule ? 5.0 : 0.0
        cfg.cornerStyle = .capsule
        cfg.contentInsets = isCapsule
          ? NSDirectionalEdgeInsets(top: 0.0, leading: 12.0, bottom: 0.0, trailing: hasTrailing ? 26.0 : 12.0)
          : .zero
        self.button.configuration = cfg
        self.button.cornerConfiguration = .capsule()
      } else {
        var cfg = useProminent ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
        cfg.image = leadingImg
        cfg.attributedTitle = titleAttr
        cfg.baseForegroundColor = foregroundColor
        if let tint = tintColor {
          cfg.baseBackgroundColor = tint
        }
        cfg.imagePadding = isCapsule ? 5.0 : 0.0
        cfg.cornerStyle = .capsule
        cfg.contentInsets = isCapsule
          ? NSDirectionalEdgeInsets(top: 0.0, leading: 12.0, bottom: 0.0, trailing: hasTrailing ? 26.0 : 12.0)
          : .zero
        self.button.configuration = cfg
      }
      #else
      var cfg = useProminent ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
      cfg.image = leadingImg
      cfg.attributedTitle = titleAttr
      cfg.baseForegroundColor = foregroundColor
      if let tint = tintColor {
        cfg.baseBackgroundColor = tint
      }
      cfg.imagePadding = isCapsule ? 5.0 : 0.0
      cfg.cornerStyle = .capsule
      cfg.contentInsets = isCapsule
        ? NSDirectionalEdgeInsets(top: 0.0, leading: 12.0, bottom: 0.0, trailing: hasTrailing ? 26.0 : 12.0)
        : .zero
      self.button.configuration = cfg
      #endif

      if let menu = menu {
        self.button.menu = menu
        self.button.showsMenuAsPrimaryAction = true
      } else {
        self.button.menu = nil
        self.button.showsMenuAsPrimaryAction = false
      }
    }
  }
}

private final class MarcoNativeGlassButtonPlatformView: NSObject, FlutterPlatformView {
  private let hostView = MarcoTraitAwareHostView(frame: .zero)
  private let glassButton = MarcoNativeGlassButtonControl(frame: .zero)
  private let channel: FlutterMethodChannel
  private var lastArgs: [String: Any] = [:]
  private var appearanceObserver: NSObjectProtocol?

  init(
    frame: CGRect,
    viewId: Int64,
    arguments args: [String: Any]?,
    messenger: FlutterBinaryMessenger
  ) {
    self.channel = FlutterMethodChannel(
      name: "marco_movie/ios26_glass_button_\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    let initialFrame = MarcoLiquidGlassSupport.resolvedInitialFrame(
      frame,
      args: args,
      defaultWidth: 40.0,
      defaultHeight: 40.0
    )
    MarcoLiquidGlassSupport.withoutAnimations {
      self.hostView.frame = initialFrame
      self.hostView.backgroundColor = .clear
      self.hostView.isOpaque = false
      self.hostView.clipsToBounds = false
      self.hostView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle

      self.glassButton.translatesAutoresizingMaskIntoConstraints = false
      self.glassButton.onTap = { [weak self] in
        self?.handleTap()
      }
      self.hostView.addSubview(self.glassButton)

      NSLayoutConstraint.activate([
        self.glassButton.topAnchor.constraint(equalTo: self.hostView.topAnchor),
        self.glassButton.bottomAnchor.constraint(equalTo: self.hostView.bottomAnchor),
        self.glassButton.leadingAnchor.constraint(equalTo: self.hostView.leadingAnchor),
        self.glassButton.trailingAnchor.constraint(equalTo: self.hostView.trailingAnchor),
      ])

      if let args = args {
        self.apply(args)
      }
      self.hostView.layoutIfNeeded()
    }

    self.hostView.onTraitChanged = { [weak self] in
      guard let self = self, !self.lastArgs.isEmpty else { return }
      self.apply(self.lastArgs)
    }
    appearanceObserver = NotificationCenter.default.addObserver(
      forName: MarcoLiquidGlassSupport.appearanceChangedNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self, !self.lastArgs.isEmpty else { return }
      self.apply(self.lastArgs)
    }

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      DispatchQueue.main.async {
        if call.method == "update", let args = call.arguments as? [String: Any] {
          self.apply(args)
          result(nil)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  deinit {
    if let obs = appearanceObserver {
      NotificationCenter.default.removeObserver(obs)
    }
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView {
    return hostView
  }

  private func apply(_ args: [String: Any]) {
    lastArgs = args
    let style = (args["style"] as? String) ?? "circle"
    let symbol = args["symbol"] as? String
    let trailingSymbol = args["trailingSymbol"] as? String
    let label = (args["label"] as? String) ?? ""
    let symbolSize = CGFloat((args["symbolSize"] as? NSNumber)?.doubleValue ?? 17.0)
    let forceDark = (args["forceDark"] as? Bool) ?? false
    let prominent = (args["prominent"] as? Bool) ?? false
    let tintColor = MarcoLiquidGlassSupport.colorFromARGB(args["tintColor"])
    let explicitFg = MarcoLiquidGlassSupport.colorFromARGB(args["foregroundColor"])
    let effectiveDark = forceDark || MarcoLiquidGlassSupport.isEffectiveDark(for: hostView)
    let fgColor: UIColor
    if let explicit = explicitFg {
      if tintColor == nil && !effectiveDark && MarcoLiquidGlassSupport.isNearWhite(explicit) {
        fgColor = MarcoLiquidGlassSupport.adaptiveGlassForeground(for: hostView, forceDark: false)
      } else if tintColor == nil && effectiveDark && MarcoLiquidGlassSupport.isNearBlack(explicit) {
        fgColor = MarcoLiquidGlassSupport.adaptiveGlassForeground(for: hostView, forceDark: true)
      } else {
        fgColor = explicit
      }
    } else if tintColor != nil {
      fgColor = .white
    } else {
      fgColor = MarcoLiquidGlassSupport.adaptiveGlassForeground(for: hostView, forceDark: forceDark)
    }
    let targetStyle: UIUserInterfaceStyle = forceDark ? .dark : MarcoLiquidGlassSupport.interfaceStyle
    hostView.tag = forceDark ? 99001 : 0
    hostView.overrideUserInterfaceStyle = targetStyle

    let a11yLabel = (args["accessibilityLabel"] as? String) ?? label
    let menuTitle = (args["menuTitle"] as? String) ?? ""
    let rawMenuItems = (args["menuItems"] as? [[String: Any]]) ?? []
    let menu = MarcoLiquidGlassSupport.buildMenu(title: menuTitle, rawItems: rawMenuItems) { [weak self] selectedId in
      self?.channel.invokeMethod("onMenuSelected", arguments: selectedId)
    }

    let isCapsuleMode = (style == "capsule" && (!label.isEmpty || (trailingSymbol != nil && !trailingSymbol!.isEmpty)))
    glassButton.configure(
      isCapsule: isCapsuleMode,
      label: label,
      symbol: symbol,
      trailingSymbol: trailingSymbol,
      foregroundColor: fgColor,
      tintColor: tintColor,
      prominent: prominent,
      symbolSize: symbolSize,
      menu: menu,
      accessibilityLabel: a11yLabel,
      forceDark: forceDark
    )
  }

  private func handleTap() {
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()
    channel.invokeMethod("onTap", arguments: nil)
  }
}

// MARK: - 3. Native iOS 26/27 Multi-Action Liquid Glass Pill (UIGlassContainerEffect + UIButton.Configuration.glass())

private final class MarcoNativeGlassPillFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return MarcoNativeGlassPillPlatformView(
      frame: frame,
      viewId: viewId,
      arguments: args as? [String: Any],
      messenger: messenger
    )
  }
}

private final class MarcoGlassPillHostView: UIView {
  let effectView: UIVisualEffectView
  let stack = UIStackView()
  var onTraitChanged: (() -> Void)?
  private var sceneObserver: NSObjectProtocol?

  override init(frame: CGRect) {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      let containerEffect = UIGlassContainerEffect()
      containerEffect.spacing = 6.0
      effectView = UIVisualEffectView(effect: containerEffect)
    } else {
      effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    }
    #else
    effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    #endif
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false
    overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle

    effectView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    effectView.backgroundColor = .clear
    effectView.translatesAutoresizingMaskIntoConstraints = false
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      effectView.cornerConfiguration = .capsule()
    } else {
      effectView.layer.cornerCurve = .continuous
      effectView.clipsToBounds = true
    }
    #else
    effectView.layer.cornerCurve = .continuous
    effectView.clipsToBounds = true
    #endif
    addSubview(effectView)

    stack.axis = .horizontal
    stack.alignment = .center
    stack.distribution = .fill
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      stack.spacing = 4.0
    } else {
      stack.spacing = 0.0
    }
    #else
    stack.spacing = 0.0
    #endif
    stack.translatesAutoresizingMaskIntoConstraints = false
    effectView.contentView.addSubview(stack)

    NSLayoutConstraint.activate([
      effectView.topAnchor.constraint(equalTo: topAnchor),
      effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
      effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
      effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: effectView.contentView.topAnchor),
      stack.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor, constant: 4.0),
      stack.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor, constant: -4.0),
    ])

    sceneObserver = NotificationCenter.default.addObserver(
      forName: MarcoLiquidGlassSupport.sceneActivationChangedNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      UIView.animate(withDuration: 0.18) {
        self.alpha = MarcoLiquidGlassSupport.isSceneActive ? 1.0 : 0.88
      }
    }
  }

  deinit {
    if let obs = sceneObserver {
      NotificationCenter.default.removeObserver(obs)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      onTraitChanged?()
    }
  }

  func configureAppearance(forceDark: Bool) {
    let targetStyle: UIUserInterfaceStyle = forceDark ? .dark : MarcoLiquidGlassSupport.interfaceStyle
    tag = forceDark ? 99001 : 0
    overrideUserInterfaceStyle = targetStyle
    effectView.overrideUserInterfaceStyle = targetStyle
    effectView.backgroundColor = .clear
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      return
    }
    #endif
    effectView.layer.cornerRadius = bounds.height * 0.5
  }
}

private final class MarcoNativeGlassPillPlatformView: NSObject, FlutterPlatformView {
  private let hostView: MarcoGlassPillHostView
  private let channel: FlutterMethodChannel
  private var buttons: [UIButton] = []
  private var separators: [UIView] = []
  private var lastArgs: [String: Any] = [:]
  private var appearanceObserver: NSObjectProtocol?

  init(
    frame: CGRect,
    viewId: Int64,
    arguments args: [String: Any]?,
    messenger: FlutterBinaryMessenger
  ) {
    let initialFrame = MarcoLiquidGlassSupport.resolvedInitialFrame(
      frame,
      args: args,
      defaultWidth: 128.0,
      defaultHeight: 40.0
    )
    self.hostView = MarcoGlassPillHostView(frame: initialFrame)
    self.channel = FlutterMethodChannel(
      name: "marco_movie/ios26_glass_pill_\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    if let args = args {
      MarcoLiquidGlassSupport.withoutAnimations {
        self.apply(args)
        self.hostView.layoutIfNeeded()
      }
    }

    self.hostView.onTraitChanged = { [weak self] in
      guard let self = self, !self.lastArgs.isEmpty else { return }
      self.apply(self.lastArgs)
    }
    appearanceObserver = NotificationCenter.default.addObserver(
      forName: MarcoLiquidGlassSupport.appearanceChangedNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self, !self.lastArgs.isEmpty else { return }
      self.apply(self.lastArgs)
    }

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      DispatchQueue.main.async {
        if call.method == "update", let args = call.arguments as? [String: Any] {
          self.apply(args)
          result(nil)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  deinit {
    if let obs = appearanceObserver {
      NotificationCenter.default.removeObserver(obs)
    }
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView {
    return hostView
  }

  private func apply(_ args: [String: Any]) {
    lastArgs = args
    guard let items = args["items"] as? [[String: Any]] else { return }
    let forceDark = (args["forceDark"] as? Bool) ?? false
    hostView.configureAppearance(forceDark: forceDark)
    let dark = forceDark || MarcoLiquidGlassSupport.isEffectiveDark(for: hostView)
    let targetStyle: UIUserInterfaceStyle = forceDark ? .dark : MarcoLiquidGlassSupport.interfaceStyle
    let sepColor = dark ? UIColor.white.withAlphaComponent(0.24) : UIColor.black.withAlphaComponent(0.14)

    var useNativeGlass26 = false
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      useNativeGlass26 = true
    }
    #endif

    if buttons.count != items.count {
      for sub in hostView.stack.arrangedSubviews {
        hostView.stack.removeArrangedSubview(sub)
        sub.removeFromSuperview()
      }
      buttons.removeAll()
      separators.removeAll()
      for idx in 0..<items.count {
        if idx > 0 && !useNativeGlass26 {
          let sep = UIView()
          sep.backgroundColor = sepColor
          sep.translatesAutoresizingMaskIntoConstraints = false
          NSLayoutConstraint.activate([
            sep.widthAnchor.constraint(equalToConstant: 0.6),
            sep.heightAnchor.constraint(equalToConstant: 18.0),
          ])
          hostView.stack.addArrangedSubview(sep)
          separators.append(sep)
        }
        let btn = UIButton(type: .system)
        btn.tag = idx
        btn.overrideUserInterfaceStyle = targetStyle
        btn.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 17.0, *) {
          btn.isSymbolAnimationEnabled = true
        }
        btn.addTarget(self, action: #selector(itemTapped(_:)), for: .touchUpInside)
        NSLayoutConstraint.activate([
          btn.widthAnchor.constraint(equalToConstant: 36.0),
          btn.heightAnchor.constraint(equalToConstant: 36.0),
        ])
        hostView.stack.addArrangedSubview(btn)
        buttons.append(btn)
      }
    }

    for sep in separators {
      sep.backgroundColor = sepColor
    }

    let defaultFg = MarcoLiquidGlassSupport.adaptiveGlassForeground(for: hostView, forceDark: forceDark)
    let symCfg = UIImage.SymbolConfiguration(pointSize: 17.5, weight: .medium)
    for (idx, item) in items.enumerated() where idx < buttons.count {
      let btn = buttons[idx]
      btn.overrideUserInterfaceStyle = targetStyle
      let symbol = (item["symbol"] as? String) ?? "circle"
      let explicitTint = MarcoLiquidGlassSupport.colorFromARGB(item["color"])
      let tint: UIColor
      if let c = explicitTint {
        if !dark && MarcoLiquidGlassSupport.isNearWhite(c) {
          tint = defaultFg
        } else if dark && MarcoLiquidGlassSupport.isNearBlack(c) {
          tint = defaultFg
        } else {
          tint = c
        }
      } else {
        tint = defaultFg
      }
      let label = (item["accessibilityLabel"] as? String) ?? symbol
      let img = UIImage(systemName: symbol, withConfiguration: symCfg)
      #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        var cfg = UIButton.Configuration.glass()
        cfg.image = img
        cfg.baseForegroundColor = tint
        cfg.cornerStyle = .capsule
        cfg.contentInsets = .zero
        btn.configuration = cfg
        btn.cornerConfiguration = .capsule()
      } else {
        var cfg = UIButton.Configuration.plain()
        cfg.image = img
        cfg.baseForegroundColor = tint
        cfg.contentInsets = .zero
        btn.configuration = cfg
      }
      #else
      var cfg = UIButton.Configuration.plain()
      cfg.image = img
      cfg.baseForegroundColor = tint
      cfg.contentInsets = .zero
      btn.configuration = cfg
      #endif
      btn.accessibilityLabel = label
    }
  }

  @objc private func itemTapped(_ sender: UIButton) {
    if #available(iOS 17.0, *) {
      sender.imageView?.addSymbolEffect(.bounce, options: .nonRepeating, animated: true)
    }
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()
    channel.invokeMethod("onAction", arguments: sender.tag)
  }
}

// MARK: - 4. Native iOS 26 UISegmentedControl (Home Categories / Library / Netdisk)

private final class MarcoNativeSegmentedControlFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return MarcoNativeSegmentedControlPlatformView(
      frame: frame,
      viewId: viewId,
      arguments: args as? [String: Any],
      messenger: messenger
    )
  }
}

private final class MarcoNativeSegmentedControlPlatformView: NSObject, FlutterPlatformView {
  private let hostView = MarcoTraitAwareHostView(frame: .zero)
  private let control = UISegmentedControl(items: [])
  private let channel: FlutterMethodChannel
  private var currentSegments: [String] = []
  private var appearanceObserver: NSObjectProtocol?

  init(
    frame: CGRect,
    viewId: Int64,
    arguments args: [String: Any]?,
    messenger: FlutterBinaryMessenger
  ) {
    self.channel = FlutterMethodChannel(
      name: "marco_movie/ios26_segmented_control_\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    let initialFrame = MarcoLiquidGlassSupport.resolvedInitialFrame(
      frame,
      args: args,
      defaultWidth: 280.0,
      defaultHeight: 36.0
    )
    MarcoLiquidGlassSupport.withoutAnimations {
      self.hostView.frame = initialFrame
      self.hostView.backgroundColor = .clear
      self.hostView.isOpaque = false
      self.hostView.clipsToBounds = false
      self.hostView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle

      self.control.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
      self.control.apportionsSegmentWidthsByContent = false
      self.control.translatesAutoresizingMaskIntoConstraints = false
      self.applySegmentTypography()
      self.control.addTarget(self, action: #selector(self.valueChanged), for: .valueChanged)
      self.hostView.addSubview(self.control)

      NSLayoutConstraint.activate([
        self.control.topAnchor.constraint(equalTo: self.hostView.topAnchor),
        self.control.bottomAnchor.constraint(equalTo: self.hostView.bottomAnchor),
        self.control.leadingAnchor.constraint(equalTo: self.hostView.leadingAnchor),
        self.control.trailingAnchor.constraint(equalTo: self.hostView.trailingAnchor),
      ])

      if let args = args {
        self.apply(args)
      }
      self.hostView.layoutIfNeeded()
    }

    self.hostView.onTraitChanged = { [weak self] in
      self?.refreshAppearance()
    }
    appearanceObserver = NotificationCenter.default.addObserver(
      forName: MarcoLiquidGlassSupport.appearanceChangedNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.refreshAppearance()
    }

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      DispatchQueue.main.async {
        switch call.method {
        case "update":
          if let args = call.arguments as? [String: Any] {
            self.apply(args)
          }
          result(nil)
        case "setSelectedIndex":
          if let idx = call.arguments as? Int,
             idx >= 0, idx < self.control.numberOfSegments,
             self.control.selectedSegmentIndex != idx {
            self.control.selectedSegmentIndex = idx
          }
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  deinit {
    if let obs = appearanceObserver {
      NotificationCenter.default.removeObserver(obs)
    }
    channel.setMethodCallHandler(nil)
  }

  private func applySegmentTypography() {
    let segDark = MarcoLiquidGlassSupport.isEffectiveDark(for: hostView)
    control.setTitleTextAttributes(
      [
        .foregroundColor: segDark ? UIColor.white.withAlphaComponent(0.76) : UIColor.label.withAlphaComponent(0.74),
        .font: UIFont.systemFont(ofSize: 13.0, weight: .semibold),
      ],
      for: .normal
    )
    control.setTitleTextAttributes(
      [
        .foregroundColor: segDark ? UIColor.white : UIColor.label,
        .font: UIFont.systemFont(ofSize: 13.0, weight: .semibold),
      ],
      for: .selected
    )
  }

  private func refreshAppearance() {
    hostView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    control.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    applySegmentTypography()
  }

  func view() -> UIView {
    return hostView
  }

  private func apply(_ args: [String: Any]) {
    if let segments = args["segments"] as? [String], segments != currentSegments {
      currentSegments = segments
      control.removeAllSegments()
      for (idx, title) in segments.enumerated() {
        control.insertSegment(withTitle: title, at: idx, animated: false)
      }
    }
    if let idx = args["selectedIndex"] as? Int,
       idx >= 0, idx < control.numberOfSegments,
       control.selectedSegmentIndex != idx {
      control.selectedSegmentIndex = idx
    }
  }

  @objc private func valueChanged() {
    let idx = control.selectedSegmentIndex
    if idx >= 0 {
      channel.invokeMethod("onChanged", arguments: idx)
    }
  }
}

// MARK: - 5. Native iOS 26 UISwitch (Liquid Glass Expanding Crystal Thumb)

private final class MarcoNativeSwitchFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return MarcoNativeSwitchPlatformView(
      frame: frame,
      viewId: viewId,
      arguments: args as? [String: Any],
      messenger: messenger
    )
  }
}

private final class MarcoNativeSwitchPlatformView: NSObject, FlutterPlatformView {
  private let hostView = MarcoTraitAwareHostView(frame: .zero)
  private let toggle = UISwitch(frame: .zero)
  private let channel: FlutterMethodChannel
  private var appearanceObserver: NSObjectProtocol?

  init(
    frame: CGRect,
    viewId: Int64,
    arguments args: [String: Any]?,
    messenger: FlutterBinaryMessenger
  ) {
    self.channel = FlutterMethodChannel(
      name: "marco_movie/ios26_switch_\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    let initialFrame = MarcoLiquidGlassSupport.resolvedInitialFrame(
      frame,
      args: args,
      defaultWidth: 51.0,
      defaultHeight: 31.0
    )
    MarcoLiquidGlassSupport.withoutAnimations {
      self.hostView.frame = initialFrame
      self.hostView.backgroundColor = .clear
      self.hostView.isOpaque = false
      self.hostView.clipsToBounds = false
      self.hostView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle

      self.toggle.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
      self.toggle.onTintColor = UIColor.systemGreen
      self.toggle.translatesAutoresizingMaskIntoConstraints = false
      self.toggle.addTarget(self, action: #selector(self.valueChanged), for: .valueChanged)
      self.hostView.addSubview(self.toggle)

      NSLayoutConstraint.activate([
        self.toggle.centerXAnchor.constraint(equalTo: self.hostView.centerXAnchor),
        self.toggle.centerYAnchor.constraint(equalTo: self.hostView.centerYAnchor),
      ])

      if let args = args {
        self.apply(args, animated: false)
      }
      self.hostView.layoutIfNeeded()
    }

    self.hostView.onTraitChanged = { [weak self] in
      guard let self = self else { return }
      self.hostView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
      self.toggle.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    }
    appearanceObserver = NotificationCenter.default.addObserver(
      forName: MarcoLiquidGlassSupport.appearanceChangedNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      self.hostView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
      self.toggle.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    }

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      DispatchQueue.main.async {
        if call.method == "update", let args = call.arguments as? [String: Any] {
          self.apply(args, animated: true)
          result(nil)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  deinit {
    if let obs = appearanceObserver {
      NotificationCenter.default.removeObserver(obs)
    }
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView {
    return hostView
  }

  private func apply(_ args: [String: Any], animated: Bool) {
    if let color = MarcoLiquidGlassSupport.colorFromARGB(args["onTintColor"]) {
      toggle.onTintColor = color
    }
    if let enabled = args["enabled"] as? Bool {
      toggle.isEnabled = enabled
    }
    if let a11y = args["accessibilityLabel"] as? String, !a11y.isEmpty {
      toggle.accessibilityLabel = a11y
    }
    if let val = args["value"] as? Bool, toggle.isOn != val {
      toggle.setOn(val, animated: animated)
    }
  }

  @objc private func valueChanged() {
    channel.invokeMethod("onChanged", arguments: toggle.isOn)
  }
}

// MARK: - 6. Native iOS 26 UISlider (Liquid Glass Magnifying Pill Thumb)

private final class MarcoNativeSliderFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return MarcoNativeSliderPlatformView(
      frame: frame,
      viewId: viewId,
      arguments: args as? [String: Any],
      messenger: messenger
    )
  }
}

private final class MarcoHitExpandedSlider: UISlider {
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    return bounds.insetBy(dx: -10.0, dy: -16.0).contains(point)
  }
}

private final class MarcoNativeSliderPlatformView: NSObject, FlutterPlatformView {
  private let hostView = MarcoTraitAwareHostView(frame: .zero)
  private let slider = MarcoHitExpandedSlider(frame: .zero)
  private let channel: FlutterMethodChannel
  private var appearanceObserver: NSObjectProtocol?

  init(
    frame: CGRect,
    viewId: Int64,
    arguments args: [String: Any]?,
    messenger: FlutterBinaryMessenger
  ) {
    self.channel = FlutterMethodChannel(
      name: "marco_movie/ios26_slider_\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    let initialFrame = MarcoLiquidGlassSupport.resolvedInitialFrame(
      frame,
      args: args,
      defaultWidth: 320.0,
      defaultHeight: 48.0
    )
    MarcoLiquidGlassSupport.withoutAnimations {
      self.hostView.frame = initialFrame
      self.hostView.backgroundColor = .clear
      self.hostView.isOpaque = false
      self.hostView.clipsToBounds = false
      self.hostView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle

      self.slider.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
      self.slider.minimumTrackTintColor = UIColor.systemBlue
      self.slider.maximumTrackTintColor = MarcoLiquidGlassSupport.isEffectiveDark(for: self.hostView)
        ? UIColor.white.withAlphaComponent(0.24)
        : UIColor.black.withAlphaComponent(0.14)
      self.slider.isContinuous = true
      self.slider.translatesAutoresizingMaskIntoConstraints = false
      self.slider.addTarget(self, action: #selector(self.valueChanged), for: .valueChanged)
      self.slider.addTarget(self, action: #selector(self.touchEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
      let tap = UITapGestureRecognizer(target: self, action: #selector(self.trackTapped(_:)))
      tap.cancelsTouchesInView = false
      self.slider.addGestureRecognizer(tap)
      self.hostView.addSubview(self.slider)

      NSLayoutConstraint.activate([
        self.slider.leadingAnchor.constraint(equalTo: self.hostView.leadingAnchor),
        self.slider.trailingAnchor.constraint(equalTo: self.hostView.trailingAnchor),
        self.slider.centerYAnchor.constraint(equalTo: self.hostView.centerYAnchor),
        self.slider.heightAnchor.constraint(greaterThanOrEqualToConstant: 44.0),
      ])

      if let args = args {
        self.apply(args)
      }
      self.hostView.layoutIfNeeded()
    }

    let refreshSliderTheme: () -> Void = { [weak self] in
      guard let self = self else { return }
      self.hostView.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
      self.slider.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
      self.slider.maximumTrackTintColor = MarcoLiquidGlassSupport.isEffectiveDark(for: self.hostView)
        ? UIColor.white.withAlphaComponent(0.24)
        : UIColor.black.withAlphaComponent(0.14)
    }
    self.hostView.onTraitChanged = refreshSliderTheme
    appearanceObserver = NotificationCenter.default.addObserver(
      forName: MarcoLiquidGlassSupport.appearanceChangedNotification,
      object: nil,
      queue: .main
    ) { _ in
      refreshSliderTheme()
    }

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      DispatchQueue.main.async {
        if call.method == "update", let args = call.arguments as? [String: Any] {
          self.apply(args)
          result(nil)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  deinit {
    if let obs = appearanceObserver {
      NotificationCenter.default.removeObserver(obs)
    }
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView {
    return hostView
  }

  private func apply(_ args: [String: Any]) {
    if let minVal = (args["min"] as? NSNumber)?.floatValue {
      slider.minimumValue = minVal
    }
    if let maxVal = (args["max"] as? NSNumber)?.floatValue {
      slider.maximumValue = maxVal
    }
    if let tint = MarcoLiquidGlassSupport.colorFromARGB(args["tintColor"]) {
      slider.minimumTrackTintColor = tint
    }
    if let a11y = args["accessibilityLabel"] as? String, !a11y.isEmpty {
      slider.accessibilityLabel = a11y
    }
    if !slider.isTracking, let val = (args["value"] as? NSNumber)?.floatValue {
      if abs(slider.value - val) > 0.0005 {
        slider.setValue(val, animated: false)
      }
    }
  }

  @objc private func trackTapped(_ gesture: UITapGestureRecognizer) {
    guard gesture.state == .ended else { return }
    let trackRect = slider.trackRect(forBounds: slider.bounds)
    guard trackRect.width > 1.0 else { return }
    let loc = gesture.location(in: slider)
    let ratio = min(max((loc.x - trackRect.minX) / trackRect.width, 0.0), 1.0)
    let newValue = slider.minimumValue + Float(ratio) * (slider.maximumValue - slider.minimumValue)
    slider.setValue(newValue, animated: true)
    UISelectionFeedbackGenerator().selectionChanged()
    channel.invokeMethod("onChanged", arguments: Double(newValue))
    channel.invokeMethod("onChangeEnd", arguments: Double(newValue))
  }

  @objc private func valueChanged() {
    channel.invokeMethod("onChanged", arguments: Double(slider.value))
  }

  @objc private func touchEnded() {
    channel.invokeMethod("onChangeEnd", arguments: Double(slider.value))
  }
}

private final class MarcoBonjourScanner: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
  private static var activeScanners: [MarcoBonjourScanner] = []

  private var browsers: [NetServiceBrowser] = []
  private var resolvingServices: [NetService] = []
  private var discoveredByKey: [String: [String: Any]] = [:]
  private var permissionDenied: Bool = false
  private var finished: Bool = false
  private var completion: (([String: Any]) -> Void)?

  static func scan(
    serviceTypes: [String],
    timeoutMs: Int,
    completion: @escaping ([String: Any]) -> Void
  ) {
    let scanner = MarcoBonjourScanner()
    activeScanners.append(scanner)
    scanner.start(serviceTypes: serviceTypes, timeoutMs: timeoutMs) { payload in
      activeScanners.removeAll { $0 === scanner }
      completion(payload)
    }
  }

  private func start(
    serviceTypes: [String],
    timeoutMs: Int,
    completion: @escaping ([String: Any]) -> Void
  ) {
    self.completion = completion
    let clampedMs = min(max(timeoutMs, 600), 6000)
    for rawType in serviceTypes {
      let trimmed = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let normalizedType = trimmed.hasSuffix(".") ? trimmed : "\(trimmed)."
      let browser = NetServiceBrowser()
      browser.delegate = self
      browser.schedule(in: .main, forMode: .common)
      browsers.append(browser)
      browser.searchForServices(ofType: normalizedType, inDomain: "local.")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(clampedMs)) { [weak self] in
      self?.finish()
    }
  }

  private func finish() {
    guard !finished else { return }
    finished = true
    for browser in browsers {
      browser.stop()
      browser.delegate = nil
    }
    browsers.removeAll()
    for svc in resolvingServices {
      svc.stop()
      svc.delegate = nil
    }
    resolvingServices.removeAll()
    let cb = completion
    completion = nil
    cb?([
      "devices": Array(discoveredByKey.values),
      "permissionDenied": permissionDenied,
    ])
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didNotSearch errorDict: [String: NSNumber]
  ) {
    if let code = errorDict[NetService.errorCode]?.intValue, code == -72008 {
      permissionDenied = true
    }
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didFind service: NetService,
    moreComing: Bool
  ) {
    guard !finished else { return }
    service.delegate = self
    service.schedule(in: .main, forMode: .common)
    resolvingServices.append(service)
    service.resolve(withTimeout: 1.5)
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    guard !finished else { return }
    guard let addresses = sender.addresses, !addresses.isEmpty else { return }
    var resolvedHost: String?
    for data in addresses {
      if let ip = Self.ipv4Address(from: data) {
        if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") { continue }
        resolvedHost = ip
        break
      }
    }
    guard let host = resolvedHost, !host.isEmpty else { return }
    let port = sender.port > 0 ? sender.port : 0
    var txtDict: [String: String] = [:]
    if let txtData = sender.txtRecordData() {
      let rawDict = NetService.dictionary(fromTXTRecord: txtData)
      for (k, v) in rawDict {
        if let str = String(data: v, encoding: .utf8), !str.isEmpty {
          txtDict[k] = str
        }
      }
    }
    let key = "\(sender.type)|\(host)|\(port)"
    discoveredByKey[key] = [
      "name": sender.name,
      "type": sender.type,
      "host": host,
      "port": port,
      "txt": txtDict,
    ]
  }

  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    if let code = errorDict[NetService.errorCode]?.intValue, code == -72008 {
      permissionDenied = true
    }
  }

  private static func ipv4Address(from addressData: Data) -> String? {
    return addressData.withUnsafeBytes { rawBuf -> String? in
      guard let base = rawBuf.baseAddress else { return nil }
      let sa = base.assumingMemoryBound(to: sockaddr.self)
      guard sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
      let sin = base.assumingMemoryBound(to: sockaddr_in.self)
      var addr = sin.pointee.sin_addr
      var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else {
        return nil
      }
      return String(cString: buf)
    }
  }
}
