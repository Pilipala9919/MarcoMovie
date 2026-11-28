"""Bundle brand logo assets, and configure Apple/Windows native shells."""
from pathlib import Path
import json
import re
import plistlib
import shutil
import struct
import subprocess
import sys
from urllib.parse import unquote, urlparse
ROOT = Path(__file__).resolve().parent
REPO_ROOT = ROOT.parent
IOS_LIQUID_GLASS_SWIFT_PATH = Path(__file__).resolve().parent / "ios_native" / "MarcoLiquidGlass.swift"
IOS_AVPLAYER_ENGINE_SWIFT_PATH = Path(__file__).resolve().parent / "ios_native" / "MarcoAvPlayerEngine.swift"
IOS_WEB_SNIFFER_JS_HOST_SWIFT_PATH = Path(__file__).resolve().parent / "ios_native" / "MarcoWebSnifferAndJsHost.swift"
_LOGO_MARK_CANDIDATES = (
    REPO_ROOT / "android-tv" / "src" / "main" / "res" / "drawable-nodpi" / "logo_mark.png",
    REPO_ROOT / "android-mobile" / "src" / "main" / "res" / "drawable-nodpi" / "logo_mark.png",
    REPO_ROOT / "android" / "src" / "main" / "res" / "drawable-nodpi" / "logo_mark.png",
    ROOT / "assets" / "logo_mark.png",
)
LOGO_MARK = next((p for p in _LOGO_MARK_CANDIDATES if p.is_file()), _LOGO_MARK_CANDIDATES[0])
OPAQUE_ICON = REPO_ROOT / "docs" / "images" / "app-icon-512.png"
MACOS_ICON_DIR = ROOT / "brand" / "macos"
IOS_ICON = ROOT / "brand" / "ios" / "1024.png"

IOS_NATIVE_CHANNEL_REGISTRAR_SWIFT = r'''

private enum MarcoNativeChannelRegistrar {
  private static func activeFlutterController() -> FlutterViewController? {
    return MarcoLiquidGlassSupport.activeWindow()?.rootViewController as? FlutterViewController
  }

  static func register(messenger: FlutterBinaryMessenger, pluginRegistry: FlutterPluginRegistry) {
    let wakelockChannel = FlutterMethodChannel(name: "marco_movie/wakelock", binaryMessenger: messenger)
    wakelockChannel.setMethodCallHandler { call, result in
      if call.method == "setEnabled", let enabled = call.arguments as? Bool {
        DispatchQueue.main.async {
          UIApplication.shared.isIdleTimerDisabled = enabled
          result(nil)
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    let systemChromeChannel = FlutterMethodChannel(name: "marco_movie/system_chrome", binaryMessenger: messenger)
    systemChromeChannel.setMethodCallHandler { call, result in
      if call.method == "setImmersive", let immersive = call.arguments as? Bool {
        DispatchQueue.main.async {
          let controller = activeFlutterController()
          if let marcoVC = controller as? MarcoFlutterViewController {
            marcoVC.marcoImmersiveMode = immersive
          } else {
            controller?.setNeedsStatusBarAppearanceUpdate()
            if #available(iOS 11.0, *) {
              controller?.setNeedsUpdateOfHomeIndicatorAutoHidden()
              controller?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            }
          }
          result(nil)
        }
      } else if call.method == "requestOrientation", let mode = call.arguments as? String {
        DispatchQueue.main.async {
          if let marcoVC = activeFlutterController() as? MarcoFlutterViewController {
            marcoVC.applyRequestedOrientation(mode)
          }
          result(nil)
        }
      } else if call.method == "setOrientationMonitoring", let enabled = call.arguments as? Bool {
        DispatchQueue.main.async {
          if let marcoVC = activeFlutterController() as? MarcoFlutterViewController {
            marcoVC.setPhysicalOrientationMonitoring(enabled, channel: systemChromeChannel)
          }
          result(nil)
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    let authChannel = FlutterMethodChannel(name: "marco_movie/netdisk_auth", binaryMessenger: messenger)
    authChannel.setMethodCallHandler { call, result in
      if call.method == "startWebAuth", let args = call.arguments as? [String: Any] {
        let drive = (args["drive"] as? String) ?? ""
        let urlStr = (args["url"] as? String) ?? ""
        let qrUrl = (args["qrUrl"] as? String) ?? ""
        DispatchQueue.main.async {
          NetdiskWebAuthController.present(
            from: activeFlutterController(),
            drive: drive,
            urlString: urlStr,
            qrUrlString: qrUrl,
            completion: result
          )
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    MarcoWebSnifferAndJsHostRegistrar.register(messenger: messenger)

    if let avRegistrar = pluginRegistry.registrar(forPlugin: "MarcoAvPlayerPlugin") {
      MarcoAvPlayerEngine.register(with: avRegistrar, messenger: avRegistrar.messenger())
    }

    if let glassRegistrar = pluginRegistry.registrar(forPlugin: "MarcoLiquidGlassPlugin") {
      MarcoLiquidGlassSupport.register(with: glassRegistrar, messenger: glassRegistrar.messenger())
    }
  }
}'''

IOS_NETDISK_AUTH_CONTROLLER_SWIFT = r'''

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
  weak var target: WKScriptMessageHandler?
  init(_ target: WKScriptMessageHandler) {
    self.target = target
  }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    target?.userContentController(userContentController, didReceive: message)
  }
}

final class NetdiskWebAuthController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKHTTPCookieStoreObserver, UIAdaptivePresentationControllerDelegate {
  private static let mobileSafariUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
  private static let desktopSafariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

  private static let baiduAppJumpScript = #"""
  (function() {
    if (location.hostname !== 'wappass.baidu.com') return;
    if (window.__marcoBaiduAppJumpTried) return;
    var tries = 0;
    var timer = setInterval(function() {
      tries++;
      var btn = document.querySelector('.other-button');
      if (btn && btn.offsetParent !== null) {
        var txt = String(btn.innerText || btn.textContent || '');
        if (txt.indexOf('登录') !== -1 || txt.indexOf('授权') !== -1) {
          window.__marcoBaiduAppJumpTried = true;
          clearInterval(timer);
          setTimeout(function() { btn.click(); }, 120);
          return;
        }
      }
      if (tries >= 24) clearInterval(timer);
    }, 250);
  })();
  """#

  private static let aliHookScript = #"""
  (function() {
    var host = String(location.hostname || '').toLowerCase();
    if (!host.endsWith('aliyundrive.com') && !host.endsWith('alipan.com')) return;
    function post(payload) {
      try {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.marcoAuth) {
          window.webkit.messageHandlers.marcoAuth.postMessage(payload);
        }
      } catch (_) {}
    }
    function inspectObject(obj) {
      if (!obj) return;
      if (typeof obj === 'string') {
        var s = obj.trim();
        if (s.charCodeAt(0) === 123) {
          try { obj = JSON.parse(s); } catch (_) { return; }
        } else {
          return;
        }
      }
      if (typeof obj !== 'object') return;
      var rt = (obj.tokenInfo && (obj.tokenInfo.refresh_token || obj.tokenInfo.refreshToken))
        || obj.refresh_token || obj.refreshToken
        || (obj.pds_login_result && (obj.pds_login_result.refreshToken || obj.pds_login_result.refresh_token))
        || (obj.data && (obj.data.refresh_token || obj.data.refreshToken));
      if (typeof rt === 'string' && rt.length >= 16 && rt.indexOf('=') === -1) {
        post({ type: 'credential', credential: 'ali_token=' + rt });
        return;
      }
      var biz = obj.bizExt || (obj.data && obj.data.bizExt) || (obj.content && obj.content.data && obj.content.data.bizExt);
      if (typeof biz === 'string' && biz.length >= 16) {
        post({ type: 'bizExt', bizExt: biz });
      }
    }
    window.addEventListener('message', function(e) {
      try { inspectObject(e && e.data); } catch (_) {}
    }, true);
    try {
      var origSetItem = Storage.prototype.setItem;
      Storage.prototype.setItem = function(k, v) {
        try {
          if (k === 'token' && typeof v === 'string') inspectObject(v);
        } catch (_) {}
        return origSetItem.apply(this, arguments);
      };
    } catch (_) {}
    try {
      var origOpen = XMLHttpRequest.prototype.open;
      var origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(m, u) {
        this.__marcoUrl = String(u || '');
        return origOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function() {
        this.addEventListener('load', function() {
          try {
            var u = this.__marcoUrl || '';
            if (u.indexOf('token') !== -1 || u.indexOf('login') !== -1 || u.indexOf('oauth') !== -1) {
              inspectObject(this.responseText);
            }
          } catch (_) {}
        });
        return origSend.apply(this, arguments);
      };
    } catch (_) {}
    try {
      if (window.fetch) {
        var origFetch = window.fetch;
        window.fetch = function() {
          var first = arguments[0];
          var u = String(first && first.url ? first.url : first || '');
          return origFetch.apply(this, arguments).then(function(res) {
            try {
              if (u.indexOf('token') !== -1 || u.indexOf('login') !== -1 || u.indexOf('oauth') !== -1) {
                res.clone().text().then(inspectObject).catch(function() {});
              }
            } catch (_) {}
            return res;
          });
        };
      }
    } catch (_) {}
  })();
  """#

  private let driveKey: String
  private let initialUrlString: String
  private let qrUrlString: String
  private var completion: FlutterResult?
  private var completed = false
  private var panAuthTriggered = false
  private var webView: WKWebView!
  private var dataStore: WKWebsiteDataStore?
  private let hintLabel = UILabel()
  private var observers: [NSObjectProtocol] = []

  init(drive: String, urlString: String, qrUrlString: String, completion: @escaping FlutterResult) {
    self.driveKey = drive
    self.initialUrlString = urlString
    self.qrUrlString = qrUrlString
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    if !completed {
      completed = true
      let callback = completion
      completion = nil
      DispatchQueue.main.async {
        callback?(nil)
      }
    }
  }

  static func present(from root: UIViewController?, drive: String, urlString: String, qrUrlString: String, completion: @escaping FlutterResult) {
    var presenter = root ?? MarcoLiquidGlassSupport.activeWindow()?.rootViewController
    while let presented = presenter?.presentedViewController, !presented.isBeingDismissed {
      presenter = presented
    }
    guard let host = presenter else {
      completion(nil)
      return
    }
    let vc = NetdiskWebAuthController(drive: drive, urlString: urlString, qrUrlString: qrUrlString, completion: completion)
    let nav = UINavigationController(rootViewController: vc)
    nav.modalPresentationStyle = .pageSheet
    nav.presentationController?.delegate = vc
    nav.overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    host.present(nav, animated: true, completion: nil)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = MarcoLiquidGlassSupport.interfaceStyle
    view.backgroundColor = MarcoLiquidGlassSupport.isEffectiveDark
      ? UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
      : UIColor.systemGroupedBackground
    switch driveKey {
    case "baidu":
      navigationItem.title = "百度网盘登录授权"
    case "ali":
      navigationItem.title = "阿里云盘登录授权"
    case "quark":
      navigationItem.title = "夸克网盘登录授权"
    case "uc":
      navigationItem.title = "UC网盘登录授权"
    default:
      navigationItem.title = "网盘账号授权"
    }
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: "关闭",
      style: .plain,
      target: self,
      action: #selector(closeTapped)
    )
    if driveKey == "ali" {
      navigationItem.rightBarButtonItem = UIBarButtonItem(
        title: "App扫码",
        style: .plain,
        target: self,
        action: #selector(openScanAppTapped)
      )
    }

    let config = WKWebViewConfiguration()
    let store = WKWebsiteDataStore.nonPersistent()
    self.dataStore = store
    config.websiteDataStore = store
    let contentController = WKUserContentController()
    contentController.add(WeakScriptMessageHandler(self), name: "marcoAuth")
    if driveKey == "ali" {
      contentController.addUserScript(
        WKUserScript(source: Self.aliHookScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
      )
    } else if driveKey == "baidu" {
      contentController.addUserScript(
        WKUserScript(source: Self.baiduAppJumpScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
      )
    }
    config.userContentController = contentController
    store.httpCookieStore.add(self)

    let banner = UIView()
    banner.translatesAutoresizingMaskIntoConstraints = false
    banner.backgroundColor = UIColor(red: 0.13, green: 0.14, blue: 0.18, alpha: 1.0)
    hintLabel.translatesAutoresizingMaskIntoConstraints = false
    hintLabel.font = UIFont.systemFont(ofSize: 12.5, weight: .medium)
    hintLabel.textColor = UIColor(white: 0.88, alpha: 1.0)
    hintLabel.numberOfLines = 2
    hintLabel.textAlignment = .center
    hintLabel.text = initialHintText()
    banner.addSubview(hintLabel)

    let wv = WKWebView(frame: .zero, configuration: config)
    wv.translatesAutoresizingMaskIntoConstraints = false
    wv.navigationDelegate = self
    wv.uiDelegate = self
    wv.allowsBackForwardNavigationGestures = true
    wv.customUserAgent = (driveKey == "baidu" || driveKey == "ali") ? Self.mobileSafariUA : Self.desktopSafariUA
    self.webView = wv

    view.addSubview(banner)
    view.addSubview(wv)
    let guide = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      banner.topAnchor.constraint(equalTo: guide.topAnchor),
      banner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      banner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hintLabel.topAnchor.constraint(equalTo: banner.topAnchor, constant: 7),
      hintLabel.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -7),
      hintLabel.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
      hintLabel.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),
      wv.topAnchor.constraint(equalTo: banner.bottomAnchor),
      wv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      wv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      wv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    let center = NotificationCenter.default
    for name in [UIApplication.didBecomeActiveNotification, UIApplication.willEnterForegroundNotification] {
      let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.handleAppForegrounded()
      }
      observers.append(token)
    }

    if let targetUrl = URL(string: resolvedInitialUrl()) {
      wv.load(URLRequest(url: targetUrl))
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || navigationController?.isBeingDismissed == true {
      finish(with: nil, dismissModal: false)
    }
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    finish(with: nil, dismissModal: false)
  }

  @objc private func closeTapped() {
    finish(with: nil, dismissModal: true)
  }

  @objc private func openScanAppTapped() {
    finish(with: ["type": "openScanApp"], dismissModal: true)
  }

  private func initialHintText() -> String {
    switch driveKey {
    case "baidu":
      for scheme in ["bdnetdisk://", "baiduyunipad://", "baiduyun://"] {
        if let u = URL(string: scheme), UIApplication.shared.canOpenURL(u) {
          return "正在唤起百度网盘 App，确认「授权登录」后返回即可自动完成登录"
        }
      }
      return "支持唤起百度 App 授权或直接在此页面登录，完成后自动同步"
    case "ali":
      return "支持本机免密 / 淘宝跳转 / 验证码登录，或点右上角用阿里云盘相册扫码"
    default:
      return "登录完成后将自动同步网盘状态并返回"
    }
  }

  private func resolvedInitialUrl() -> String {
    guard driveKey == "baidu" else { return initialUrlString }
    let candidates: [(scheme: String, authApp: String, appScheme: String)] = [
      ("bdnetdisk://", "netDisk", "bdnetdisk"),
      ("baiduyunipad://", "netDisk", "baiduyunipad"),
      ("baiduyun://", "netDisk", "baiduyun"),
      ("baiduboxapp://", "baidu", "baiduboxapp"),
    ]
    for item in candidates {
      if let probe = URL(string: item.scheme), UIApplication.shared.canOpenURL(probe) {
        let sep = initialUrlString.contains("?") ? "&" : "?"
        return "\(initialUrlString)\(sep)authApp=\(item.authApp)&appScheme=\(item.appScheme)"
      }
    }
    return initialUrlString
  }

  private func handleAppForegrounded() {
    guard !completed, let wv = webView else { return }
    if driveKey == "baidu" {
      wv.evaluateJavaScript(
        "try { document.dispatchEvent(new Event('visibilitychange')); window.dispatchEvent(new Event('focus')); window.dispatchEvent(new Event('pageshow')); } catch (_) {}",
        completionHandler: nil
      )
    }
    inspectCookies()
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.allow)
      return
    }
    let scheme = (url.scheme ?? "").lowercased()
    if ["http", "https", "about", "data", "blob", "javascript"].contains(scheme) {
      decisionHandler(.allow)
      return
    }
    if scheme == "marcomovie" {
      handleAppForegrounded()
      decisionHandler(.cancel)
      return
    }
    var targetUrl = url
    let raw = url.absoluteString
    if raw.contains("com.baidu.passport/grantweb") {
      let patched = raw.replacingOccurrences(of: "browserScheme=&", with: "browserScheme=marcomovie%3A%2F%2Fauth&")
      let finalStr = patched.hasSuffix("browserScheme=") ? (patched + "marcomovie%3A%2F%2Fauth") : patched
      if let rewritten = URL(string: finalStr) {
        targetUrl = rewritten
      }
    }
    UIApplication.shared.open(targetUrl, options: [:], completionHandler: nil)
    decisionHandler(.cancel)
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
      let scheme = (url.scheme ?? "").lowercased()
      if ["http", "https"].contains(scheme) {
        webView.load(navigationAction.request)
      } else {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
      }
    }
    return nil
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    inspectCookies()
  }

  func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
    inspectCookies()
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.name == "marcoAuth", !completed else { return }
    guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
    if type == "credential", let cred = body["credential"] as? String, !cred.isEmpty {
      finish(with: ["type": "credential", "credential": cred], dismissModal: true)
    } else if type == "bizExt", let biz = body["bizExt"] as? String, !biz.isEmpty {
      finish(with: ["type": "bizExt", "bizExt": biz], dismissModal: true)
    }
  }

  private func inspectCookies() {
    guard !completed, let store = dataStore?.httpCookieStore else { return }
    store.getAllCookies { [weak self] cookies in
      guard let self = self, !self.completed else { return }
      let now = Date()
      let valid = cookies.filter { c in
        if c.value.isEmpty { return false }
        if let exp = c.expiresDate, exp <= now { return false }
        return true
      }
      switch self.driveKey {
      case "baidu":
        self.evaluateBaiduCookies(valid)
      case "quark":
        self.evaluateQuarkCookies(valid)
      case "uc":
        self.evaluateUcCookies(valid)
      default:
        break
      }
    }
  }

  private func evaluateBaiduCookies(_ valid: [HTTPCookie]) {
    var bduss = ""
    var panStoken = ""
    var rootStoken = ""
    var extra: [String: String] = [:]
    let allowedNames: Set<String> = ["BDUSS", "STOKEN", "PTOKEN", "BAIDUID", "PANPSC", "csrfToken"]
    for c in valid {
      guard allowedNames.contains(c.name) else { continue }
      let dom = c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
      guard dom == "baidu.com" || dom == "pan.baidu.com" else { continue }
      if c.name == "BDUSS" {
        bduss = c.value
      } else if c.name == "STOKEN" {
        if dom == "pan.baidu.com" {
          panStoken = c.value
        } else {
          rootStoken = c.value
        }
      } else if dom == "pan.baidu.com" || extra[c.name] == nil {
        extra[c.name] = c.value
      }
    }
    guard !bduss.isEmpty else { return }
    let bestStoken = !panStoken.isEmpty ? panStoken : rootStoken
    if !panStoken.isEmpty {
      finishBaiduWith(bduss: bduss, stoken: bestStoken, extra: extra)
      return
    }
    if !panAuthTriggered {
      panAuthTriggered = true
      hintLabel.text = "已获取百度授权，正在同步网盘会话…"
      webView.customUserAgent = Self.desktopSafariUA
      if let authUrl = URL(string: "https://passport.baidu.com/v3/login/api/auth?return_type=3&tpl=netdisk&u=https%3A%2F%2Fpan.baidu.com%2Fdisk%2Fhome") {
        webView.load(URLRequest(url: authUrl))
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
        guard let self = self, !self.completed else { return }
        self.dataStore?.httpCookieStore.getAllCookies { [weak self] latest in
          guard let self = self, !self.completed else { return }
          let now = Date()
          var finalBduss = ""
          var finalStoken = ""
          var finalExtra: [String: String] = [:]
          for c in latest {
            if c.value.isEmpty { continue }
            if let exp = c.expiresDate, exp <= now { continue }
            let dom = c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            guard dom == "baidu.com" || dom == "pan.baidu.com" else { continue }
            if c.name == "BDUSS" {
              finalBduss = c.value
            } else if c.name == "STOKEN" {
              if dom == "pan.baidu.com" || finalStoken.isEmpty {
                finalStoken = c.value
              }
            } else if ["PTOKEN", "BAIDUID", "PANPSC", "csrfToken"].contains(c.name) {
              if dom == "pan.baidu.com" || finalExtra[c.name] == nil {
                finalExtra[c.name] = c.value
              }
            }
          }
          if !finalBduss.isEmpty {
            self.finishBaiduWith(bduss: finalBduss, stoken: finalStoken, extra: finalExtra)
          }
        }
      }
    } else if webView.url?.host?.lowercased() == "pan.baidu.com" && !bestStoken.isEmpty {
      finishBaiduWith(bduss: bduss, stoken: bestStoken, extra: extra)
    }
  }

  private func finishBaiduWith(bduss: String, stoken: String, extra: [String: String]) {
    var parts: [String] = ["BDUSS=\(bduss)"]
    if !stoken.isEmpty {
      parts.append("STOKEN=\(stoken)")
    }
    for key in ["PTOKEN", "BAIDUID", "PANPSC", "csrfToken"] {
      if let v = extra[key], !v.isEmpty {
        parts.append("\(key)=\(v)")
      }
    }
    finish(with: ["type": "credential", "credential": parts.joined(separator: "; ")], dismissModal: true)
  }

  private func evaluateQuarkCookies(_ valid: [HTTPCookie]) {
    var map: [String: String] = [:]
    for c in valid {
      let dom = c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
      if dom == "quark.cn" || dom.hasSuffix(".quark.cn") {
        map[c.name] = c.value
      }
    }
    guard let pus = map["__pus"], !pus.isEmpty, let puus = map["__puus"], !puus.isEmpty else { return }
    let header = map.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    finish(with: ["type": "credential", "credential": header], dismissModal: true)
  }

  private func evaluateUcCookies(_ valid: [HTTPCookie]) {
    var map: [String: String] = [:]
    for c in valid {
      let dom = c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
      if dom == "uc.cn" || dom.hasSuffix(".uc.cn") {
        map[c.name] = c.value
      }
    }
    let pus = map["__pus"] ?? ""
    let puus = map["__puus"] ?? ""
    guard !pus.isEmpty || !puus.isEmpty else { return }
    let header = map.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    finish(with: ["type": "credential", "credential": header], dismissModal: true)
  }

  private func cleanupObservers() {
    let center = NotificationCenter.default
    for token in observers {
      center.removeObserver(token)
    }
    observers.removeAll()
    if let store = dataStore?.httpCookieStore {
      store.remove(self)
    }
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "marcoAuth")
    webView?.stopLoading()
  }

  private func finish(with value: Any?, dismissModal: Bool) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.finish(with: value, dismissModal: dismissModal)
      }
      return
    }
    guard !completed else { return }
    completed = true
    cleanupObservers()
    let callback = completion
    completion = nil
    let target = navigationController ?? self
    if dismissModal, target.presentingViewController != nil, !target.isBeingDismissed {
      target.dismiss(animated: true) {
        callback?(value)
      }
    } else {
      callback?(value)
    }
  }
}
'''

IOS_WEB_SNIFFER_CHANNEL_SNIPPET = r'''
      let snifferChannel = FlutterMethodChannel(name: "marco_movie/web_sniffer", binaryMessenger: controller.binaryMessenger)
      snifferChannel.setMethodCallHandler { call, result in
        if call.method == "sniffMedia", let args = call.arguments as? [String: Any] {
          let urlStr = (args["url"] as? String) ?? ""
          let rawHeaders = (args["headers"] as? [String: Any]) ?? [:]
          var headers: [String: String] = [:]
          for (k, v) in rawHeaders {
            headers[k] = String(describing: v)
          }
          let timeoutMs = (args["timeoutMs"] as? Int) ?? 12000
          HeadlessMediaWebSniffer.sniff(urlString: urlStr, headers: headers, timeoutMs: timeoutMs, completion: result)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }'''

MACOS_WEB_SNIFFER_CHANNEL_SNIPPET = r'''
    let snifferChannel = FlutterMethodChannel(name: "marco_movie/web_sniffer", binaryMessenger: flutterViewController.engine.binaryMessenger)
    snifferChannel.setMethodCallHandler { call, result in
      if call.method == "sniffMedia", let args = call.arguments as? [String: Any] {
        let urlStr = (args["url"] as? String) ?? ""
        let rawHeaders = (args["headers"] as? [String: Any]) ?? [:]
        var headers: [String: String] = [:]
        for (k, v) in rawHeaders {
          headers[k] = String(describing: v)
        }
        let timeoutMs = (args["timeoutMs"] as? Int) ?? 12000
        HeadlessMediaWebSniffer.sniff(urlString: urlStr, headers: headers, timeoutMs: timeoutMs, completion: result)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }'''

MACOS_WINDOW_CHANNEL_SNIPPET = r'''
    let macosWindowChannel = FlutterMethodChannel(name: "marco_movie/macos_window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    self.marcoWindowChannel = macosWindowChannel
    macosWindowChannel.setMethodCallHandler { [weak self] call, result in
      DispatchQueue.main.async {
        guard let self = self else {
          result(nil)
          return
        }
        self.marcoHandleWindowMethodCall(call, result: result)
      }
    }'''

MACOS_WINDOW_EXTENSION_SWIFT = r'''
extension MainFlutterWindow {
  private static let marcoWindowFrameDefaultsKey = "marco_macos_window_frame_v1"
  private static let marcoMinWindowSize = NSSize(width: 720, height: 520)
  private static let marcoDefaultWindowSize = NSSize(width: 1280, height: 760)
  private static let marcoMinVisibleWidth: CGFloat = 180
  private static let marcoMinVisibleHeight: CGFloat = 80
  private static let marcoDisplayChangedNotification = Notification.Name("MarcoMovieDisplayChanged")

  private static func marcoIsValidFrame(_ frame: NSRect) -> Bool {
    return frame.origin.x.isFinite
      && frame.origin.y.isFinite
      && frame.size.width.isFinite
      && frame.size.height.isFinite
      && frame.size.width >= marcoMinWindowSize.width
      && frame.size.height >= marcoMinWindowSize.height
      && frame.size.width <= 16384
      && frame.size.height <= 16384
      && frame.origin.x > -16000
      && frame.origin.y > -16000
      && frame.origin.x < 32768
      && frame.origin.y < 32768
  }

  private static func marcoCenteredFrame(in visibleFrame: NSRect, preferredSize: NSSize) -> NSRect {
    let safeW = visibleFrame.width > 0 ? visibleFrame.width : marcoDefaultWindowSize.width
    let safeH = visibleFrame.height > 0 ? visibleFrame.height : marcoDefaultWindowSize.height
    let minW = min(marcoMinWindowSize.width, safeW)
    let minH = min(marcoMinWindowSize.height, safeH)
    let targetW: CGFloat
    if preferredSize.width <= safeW {
      targetW = max(minW, preferredSize.width)
    } else {
      targetW = min(safeW, max(minW, safeW - 24))
    }
    let targetH: CGFloat
    if preferredSize.height <= safeH {
      targetH = max(minH, preferredSize.height)
    } else {
      targetH = min(safeH, max(minH, safeH - 24))
    }
    let x = visibleFrame.minX + (safeW - targetW) / 2.0
    let y = visibleFrame.minY + (safeH - targetH) / 2.0
    return NSRect(x: x.rounded(), y: y.rounded(), width: targetW.rounded(), height: targetH.rounded())
  }

  private static func marcoResolveFrame(
    saved: NSRect?,
    visibleFrames: [NSRect],
    primaryVisibleFrame: NSRect
  ) -> NSRect {
    let validFrames = visibleFrames.filter { $0.width > 0 && $0.height > 0 }
    let primary = (primaryVisibleFrame.width > 0 && primaryVisibleFrame.height > 0)
      ? primaryVisibleFrame
      : (validFrames.first ?? NSRect(x: 0, y: 0, width: 1440, height: 875))

    guard let candidate = saved, marcoIsValidFrame(candidate) else {
      return marcoCenteredFrame(in: primary, preferredSize: marcoDefaultWindowSize)
    }
    if validFrames.isEmpty {
      return candidate
    }

    var bestFrame: NSRect?
    var bestArea: CGFloat = -1
    var bestInter = NSRect.zero
    for frame in validFrames {
      let inter = candidate.intersection(frame)
      if inter.isNull || inter.width <= 0 || inter.height <= 0 { continue }
      let area = inter.width * inter.height
      if area > bestArea {
        bestArea = area
        bestFrame = frame
        bestInter = inter
      }
    }

    guard let target = bestFrame, bestInter.width >= 120, bestInter.height >= marcoMinVisibleHeight else {
      return marcoCenteredFrame(in: primary, preferredSize: candidate.size)
    }

    let minW = min(marcoMinWindowSize.width, target.width)
    let minH = min(marcoMinWindowSize.height, target.height)
    let clampedW = min(target.width, max(minW, candidate.width))
    let clampedH = min(target.height, max(minH, candidate.height))

    let minX = target.minX
    let maxX = max(target.minX, target.maxX - min(marcoMinVisibleWidth, clampedW))
    let clampedX = min(maxX, max(minX, candidate.minX))

    let minTopY = min(target.maxY, target.minY + min(marcoMinVisibleHeight, clampedH))
    let clampedTopY = min(target.maxY, max(minTopY, candidate.minY + clampedH))
    let clampedY = clampedTopY - clampedH

    return NSRect(
      x: clampedX.rounded(),
      y: clampedY.rounded(),
      width: clampedW.rounded(),
      height: clampedH.rounded()
    )
  }

  private static func marcoEncodeFrame(_ frame: NSRect) -> [String: Double] {
    return [
      "x": Double(frame.origin.x),
      "y": Double(frame.origin.y),
      "width": Double(frame.size.width),
      "height": Double(frame.size.height),
    ]
  }

  private static func marcoDecodeFrame(_ dict: [String: Any]?) -> NSRect? {
    guard let dict = dict,
          let x = (dict["x"] as? NSNumber)?.doubleValue,
          let y = (dict["y"] as? NSNumber)?.doubleValue,
          let w = (dict["width"] as? NSNumber)?.doubleValue,
          let h = (dict["height"] as? NSNumber)?.doubleValue else {
      return nil
    }
    let rect = NSRect(x: x, y: y, width: w, height: h)
    return marcoIsValidFrame(rect) ? rect : nil
  }

  private static func marcoLoadSavedFrame() -> NSRect? {
    let raw = UserDefaults.standard.dictionary(forKey: marcoWindowFrameDefaultsKey)
    return marcoDecodeFrame(raw)
  }

  func marcoCurrentDisplayID() -> CGDirectDisplayID {
    let screen = self.screen ?? NSScreen.main ?? NSScreen.screens.first
    if let num = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
      return CGDirectDisplayID(num.uint32Value)
    }
    return CGMainDisplayID()
  }

  func marcoBuildDisplayRefreshInfo() -> [String: Any] {
    let screen = self.screen ?? NSScreen.main ?? NSScreen.screens.first
    let displayID = self.marcoCurrentDisplayID()
    var refreshHz: Double = 0
    var source = "unknown"
    var isVariableRefresh = false
    var cgModeRate: Double = 0
    if let mode = CGDisplayCopyDisplayMode(displayID) {
      cgModeRate = mode.refreshRate
    }
    if #available(macOS 12.0, *), let sc = screen {
      let maxFps = Double(sc.maximumFramesPerSecond)
      if maxFps >= 23.0 && maxFps <= 480.0 {
        if cgModeRate >= 23.0 && cgModeRate <= 480.0 && abs(cgModeRate - maxFps) <= 1.0 {
          refreshHz = cgModeRate
          source = "cg_display_mode"
        } else {
          refreshHz = maxFps
          source = "nsscreen_max_fps"
        }
        if maxFps >= 120.0 && cgModeRate == 0 {
          isVariableRefresh = true
        }
      }
    }
    if refreshHz <= 0 && cgModeRate >= 23.0 && cgModeRate <= 480.0 {
      refreshHz = cgModeRate
      source = "cg_display_mode"
    }
    var probeLink: CVDisplayLink?
    let canCreateDisplayLink = (CVDisplayLinkCreateWithCGDisplay(displayID, &probeLink) == kCVReturnSuccess && probeLink != nil)
    if refreshHz <= 0, let link = probeLink {
      let period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
      // kCVTimeIsIndefinite == 1 << 0 (fixed CoreVideo ABI bit in CVTime.flags)
      if (period.flags & Int32(1)) == 0 && period.timeValue > 0 {
        let hz = Double(period.timeScale) / Double(period.timeValue)
        if hz >= 23.0 && hz <= 480.0 {
          refreshHz = hz
          source = "cv_display_link"
        }
      }
    }
    let envFlag = getenv("MARCO_MPV_VSYNC_PACED").map { String(cString: $0) }
    let vsyncPaced: Bool
    if envFlag == "1" {
      vsyncPaced = true
    } else if envFlag == "0" {
      vsyncPaced = false
    } else {
      vsyncPaced = canCreateDisplayLink
    }
    var screenName = ""
    if #available(macOS 10.15, *), let sc = screen {
      screenName = sc.localizedName
    }
    return [
      "refreshRateHz": refreshHz,
      "vsyncPaced": vsyncPaced,
      "isVariableRefresh": isVariableRefresh,
      "source": source,
      "screenName": screenName,
    ]
  }

  func marcoNotifyDisplayChanged() {
    let displayID = self.marcoCurrentDisplayID()
    NotificationCenter.default.post(
      name: Self.marcoDisplayChangedNotification,
      object: nil,
      userInfo: ["displayID": NSNumber(value: displayID)]
    )
    self.marcoWindowChannel?.invokeMethod(
      "onDisplayRefreshRateChanged",
      arguments: self.marcoBuildDisplayRefreshInfo()
    )
  }

  func marcoRestoreInitialFrame() {
    let screens = NSScreen.screens
    let visibleFrames = screens.map { $0.visibleFrame }
    let primary = screens.first?.visibleFrame
      ?? NSScreen.main?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1440, height: 875)
    let saved = Self.marcoLoadSavedFrame()
    let resolved = Self.marcoResolveFrame(
      saved: saved,
      visibleFrames: visibleFrames,
      primaryVisibleFrame: primary
    )
    self.marcoRestoredFromSaved = (saved != nil)
    self.marcoLastNormalFrame = (saved != nil) ? resolved : nil
    self.setFrame(resolved, display: true)
  }

  func marcoEnsureWindowChromeVisible() {
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)
    if !self.styleMask.contains(.fullScreen) {
      self.standardWindowButton(.closeButton)?.isHidden = false
      self.standardWindowButton(.miniaturizeButton)?.isHidden = false
      self.standardWindowButton(.zoomButton)?.isHidden = false
    }
  }

  func marcoClampVisibleIfNeeded() {
    guard !self.marcoInFullscreenTransition,
          !self.marcoIsMiniaturizing,
          !self.marcoIsClosing,
          !self.styleMask.contains(.fullScreen),
          !self.isMiniaturized else {
      return
    }
    let screens = NSScreen.screens
    guard !screens.isEmpty else { return }
    let visibleFrames = screens.map { $0.visibleFrame }
    let primary = screens[0].visibleFrame
    let current = self.frame
    let clamped = Self.marcoResolveFrame(
      saved: current,
      visibleFrames: visibleFrames,
      primaryVisibleFrame: primary
    )
    if abs(clamped.origin.x - current.origin.x) > 1
        || abs(clamped.origin.y - current.origin.y) > 1
        || abs(clamped.size.width - current.size.width) > 1
        || abs(clamped.size.height - current.size.height) > 1 {
      self.setFrame(clamped, display: true)
      self.marcoLastNormalFrame = clamped
    }
  }

  func marcoPersistNormalFrame(forceSynchronize: Bool = false) {
    guard !self.marcoInFullscreenTransition,
          !self.marcoIsMiniaturizing,
          !self.marcoIsClosing,
          !self.styleMask.contains(.fullScreen),
          !self.isMiniaturized,
          self.isVisible else {
      return
    }
    let current = self.frame
    guard Self.marcoIsValidFrame(current) else { return }
    self.marcoLastNormalFrame = current
    UserDefaults.standard.set(Self.marcoEncodeFrame(current), forKey: Self.marcoWindowFrameDefaultsKey)
    if forceSynchronize {
      UserDefaults.standard.synchronize()
    }
  }

  func marcoFlushLastNormalFrameOnTerminate() {
    if self.isVisible {
      self.marcoPersistNormalFrame(forceSynchronize: true)
      return
    }
    if let last = self.marcoLastNormalFrame, Self.marcoIsValidFrame(last) {
      UserDefaults.standard.set(Self.marcoEncodeFrame(last), forKey: Self.marcoWindowFrameDefaultsKey)
      UserDefaults.standard.synchronize()
    }
  }

  func marcoInstallWindowObservers() {
    guard self.marcoWindowObservers.isEmpty else { return }
    let nc = NotificationCenter.default
    let add: (Notification.Name, Any?, @escaping (MainFlutterWindow) -> Void) -> Void = { [weak self] name, obj, block in
      guard let self = self else { return }
      let token = nc.addObserver(forName: name, object: obj, queue: .main) { [weak self] _ in
        guard let strongSelf = self else { return }
        block(strongSelf)
      }
      self.marcoWindowObservers.append(token)
    }

    add(NSWindow.didMoveNotification, self) { win in
      win.marcoPersistNormalFrame()
    }
    add(NSWindow.didResizeNotification, self) { win in
      win.marcoPersistNormalFrame()
    }
    add(NSWindow.didEndLiveResizeNotification, self) { win in
      win.marcoPersistNormalFrame(forceSynchronize: true)
    }
    add(NSWindow.didChangeScreenNotification, self) { win in
      win.marcoNotifyDisplayChanged()
    }
    add(NSWindow.willEnterFullScreenNotification, self) { win in
      win.marcoPersistNormalFrame(forceSynchronize: true)
      win.marcoInFullscreenTransition = true
    }
    add(NSWindow.didEnterFullScreenNotification, self) { win in
      win.marcoInFullscreenTransition = false
      win.marcoNotifyDisplayChanged()
    }
    add(NSWindow.willExitFullScreenNotification, self) { win in
      win.marcoInFullscreenTransition = true
    }
    add(NSWindow.didExitFullScreenNotification, self) { win in
      win.marcoInFullscreenTransition = false
      win.marcoEnsureWindowChromeVisible()
      win.marcoClampVisibleIfNeeded()
      win.marcoPersistNormalFrame(forceSynchronize: true)
      win.marcoNotifyDisplayChanged()
    }
    add(NSWindow.willMiniaturizeNotification, self) { win in
      win.marcoPersistNormalFrame(forceSynchronize: true)
      win.marcoIsMiniaturizing = true
    }
    add(NSWindow.didDeminiaturizeNotification, self) { win in
      win.marcoIsMiniaturizing = false
      win.marcoEnsureWindowChromeVisible()
      win.marcoClampVisibleIfNeeded()
    }
    add(NSWindow.willCloseNotification, self) { win in
      win.marcoPersistNormalFrame(forceSynchronize: true)
      win.marcoIsClosing = true
    }
    add(NSApplication.willTerminateNotification, nil) { win in
      win.marcoFlushLastNormalFrameOnTerminate()
    }
    add(NSApplication.didChangeScreenParametersNotification, nil) { win in
      win.marcoClampVisibleIfNeeded()
      win.marcoEnsureWindowChromeVisible()
      win.marcoNotifyDisplayChanged()
    }
  }

  func marcoHandleWindowMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getWindowBoundsState":
      var payload: [String: Any] = [
        "restoredFromSaved": self.marcoRestoredFromSaved,
        "isFullScreen": self.styleMask.contains(.fullScreen) || self.marcoInFullscreenTransition,
        "isMiniaturized": self.isMiniaturized || self.marcoIsMiniaturizing,
        "minWidth": Double(self.minSize.width),
        "minHeight": Double(self.minSize.height),
        "currentFrame": Self.marcoEncodeFrame(self.frame),
      ]
      if let saved = Self.marcoLoadSavedFrame() ?? (self.marcoRestoredFromSaved ? self.marcoLastNormalFrame : nil) {
        payload["savedFrame"] = Self.marcoEncodeFrame(saved)
      }
      result(payload)
    case "getDisplayRefreshInfo":
      result(self.marcoBuildDisplayRefreshInfo())
    case "saveNormalBounds":
      self.marcoPersistNormalFrame(forceSynchronize: true)
      result(true)
    case "applyNormalBounds":
      guard !self.styleMask.contains(.fullScreen),
            !self.isMiniaturized,
            let dict = call.arguments as? [String: Any],
            let requested = Self.marcoDecodeFrame(dict) else {
        result(false)
        return
      }
      let screens = NSScreen.screens
      let visibleFrames = screens.map { $0.visibleFrame }
      let primary = screens.first?.visibleFrame
        ?? NSScreen.main?.visibleFrame
        ?? NSRect(x: 0, y: 0, width: 1440, height: 875)
      let resolved = Self.marcoResolveFrame(
        saved: requested,
        visibleFrames: visibleFrames,
        primaryVisibleFrame: primary
      )
      self.setFrame(resolved, display: true)
      self.marcoEnsureWindowChromeVisible()
      self.marcoRestoredFromSaved = true
      self.marcoLastNormalFrame = resolved
      UserDefaults.standard.set(Self.marcoEncodeFrame(resolved), forKey: Self.marcoWindowFrameDefaultsKey)
      UserDefaults.standard.synchronize()
      result(true)
    case "setAppearance":
      let mode = (call.arguments as? String)?.lowercased() ?? "system"
      switch mode {
      case "light":
        self.appearance = NSAppearance(named: .aqua)
      case "dark":
        self.appearance = NSAppearance(named: .darkAqua)
      default:
        self.appearance = nil
      }
      self.marcoEnsureWindowChromeVisible()
      result(nil)
    case "revealInFinder":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            !path.isEmpty,
            FileManager.default.fileExists(atPath: path) else {
        result(false)
        return
      }
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
      result(true)
    case "pickLocalFile":
      let args = call.arguments as? [String: Any]
      let maxBytes = (args?["maxBytes"] as? NSNumber)?.intValue ?? (16 * 1024 * 1024)
      let panel = NSOpenPanel()
      panel.canChooseFiles = true
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = false
      panel.canCreateDirectories = false
      panel.resolvesAliases = true
      if let title = args?["title"] as? String, !title.isEmpty {
        panel.message = title
      }
      NSApp.activate(ignoringOtherApps: true)
      let handleSelection: (NSApplication.ModalResponse) -> Void = { response in
        guard response == .OK, let url = panel.url else {
          result(nil)
          return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
          if accessed {
            url.stopAccessingSecurityScopedResource()
          }
        }
        do {
          let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
          if let size = (attrs[.size] as? NSNumber)?.intValue, size > maxBytes {
            let maxMb = max(1, (maxBytes + 1024 * 1024 - 1) / (1024 * 1024))
            result(["error": "文件超过 \(maxMb) MB"])
            return
          }
          let data = try Data(contentsOf: url)
          if data.count > maxBytes {
            let maxMb = max(1, (maxBytes + 1024 * 1024 - 1) / (1024 * 1024))
            result(["error": "文件超过 \(maxMb) MB"])
            return
          }
          result([
            "name": url.lastPathComponent,
            "path": url.path,
            "bytes": FlutterStandardTypedData(bytes: data),
          ])
        } catch {
          result(["error": error.localizedDescription])
        }
      }
      if self.isVisible {
        panel.beginSheetModal(for: self, completionHandler: handleSelection)
      } else {
        handleSelection(panel.runModal())
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
'''

APPLE_WEB_SNIFFER_SWIFT = r'''

private final class WeakSnifferScriptHandler: NSObject, WKScriptMessageHandler {
  weak var target: WKScriptMessageHandler?
  init(_ target: WKScriptMessageHandler) {
    self.target = target
  }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    target?.userContentController(userContentController, didReceive: message)
  }
}

private final class HeadlessMediaWebSniffer: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
  private static var activeSniffers: Set<HeadlessMediaWebSniffer> = []
  private static let desktopSafariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

  private static let hookScript = #"""
  (function() {
    if (window.__marcoMediaSnifferInstalled) return;
    window.__marcoMediaSnifferInstalled = true;
    function looksMedia(raw) {
      if (!raw || typeof raw !== 'string') return false;
      var s = raw.trim();
      if (!s || s.indexOf('blob:') === 0 || s.indexOf('data:') === 0 || s.indexOf('javascript:') === 0) return false;
      var abs = s;
      try { abs = new URL(s, location.href).href; } catch (_) { return false; }
      if (abs.indexOf('http://') !== 0 && abs.indexOf('https://') !== 0 && abs.indexOf('rtmp://') !== 0 && abs.indexOf('rtsp://') !== 0) return false;
      var lower = abs.toLowerCase();
      if (/\.(?:js|mjs|css|png|jpe?g|gif|webp|svg|ico|woff2?|ttf|json|xml|vtt|srt|html?|php)(?:$|[?#])/.test(lower)) return false;
      return /\.(?:m3u8?|mp4|flv|mkv|mpd|webm|m4v|mov)(?:$|[?#])/.test(lower) || /[?&](?:type|format|mime)=[^&#]*(?:m3u8|mp4|flv|mpegurl|video)/.test(lower);
    }
    function report(raw) {
      try {
        if (!looksMedia(raw)) return;
        var abs = new URL(raw.trim(), location.href).href;
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.marcoSniffer) {
          window.webkit.messageHandlers.marcoSniffer.postMessage({
            url: abs,
            pageUrl: String(location.href || '')
          });
        }
      } catch (_) {}
    }
    try {
      var origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(m, u) {
        try { report(String(u || '')); } catch (_) {}
        return origOpen.apply(this, arguments);
      };
    } catch (_) {}
    try {
      if (window.fetch) {
        var origFetch = window.fetch;
        window.fetch = function() {
          try {
            var first = arguments[0];
            report(String(first && first.url ? first.url : first || ''));
          } catch (_) {}
          return origFetch.apply(this, arguments);
        };
      }
    } catch (_) {}
    try {
      var desc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
      if (desc && desc.set) {
        Object.defineProperty(HTMLMediaElement.prototype, 'src', {
          configurable: true,
          get: desc.get,
          set: function(v) {
            try { report(String(v || '')); } catch (_) {}
            return desc.set.call(this, v);
          }
        });
      }
    } catch (_) {}
    function scanDom() {
      try {
        var videos = document.querySelectorAll('video, source');
        for (var i = 0; i < videos.length; i++) {
          var el = videos[i];
          if (el.tagName === 'VIDEO') {
            try { el.muted = true; } catch (_) {}
            if (el.currentSrc) report(el.currentSrc);
          }
          if (el.src) report(el.src);
          var attr = el.getAttribute && el.getAttribute('src');
          if (attr) report(attr);
        }
      } catch (_) {}
    }
    setInterval(scanDom, 350);
    document.addEventListener('DOMContentLoaded', scanDom, true);
  })();
  """#

  private let targetUrl: URL
  private let headers: [String: String]
  private let timeoutMs: Int
  private var effectiveUa: String
  private var completion: FlutterResult?
  private var completed = false
  private var webView: WKWebView?
  private var dataStore: WKWebsiteDataStore?

  private init(targetUrl: URL, headers: [String: String], timeoutMs: Int, completion: @escaping FlutterResult) {
    self.targetUrl = targetUrl
    self.headers = headers
    self.timeoutMs = timeoutMs
    self.effectiveUa = Self.desktopSafariUA
    for (k, v) in headers {
      if k.lowercased() == "user-agent" && !v.trimmingCharacters(in: .whitespaces).isEmpty && !v.lowercased().hasPrefix("okhttp/") {
        self.effectiveUa = v
        break
      }
    }
    self.completion = completion
    super.init()
  }

  static func sniff(urlString: String, headers: [String: String], timeoutMs: Int, completion: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = url.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            url.host != nil else {
        completion(nil)
        return
      }
      let instance = HeadlessMediaWebSniffer(targetUrl: url, headers: headers, timeoutMs: timeoutMs, completion: completion)
      activeSniffers.insert(instance)
      instance.start()
    }
  }

  private static func looksLikePlayableMedia(_ raw: String) -> Bool {
    let lower = raw.lowercased()
    if lower.range(of: #"\.(?:js|mjs|css|png|jpe?g|gif|webp|svg|ico|woff2?|ttf|json|xml|vtt|srt|html?|php)(?:$|[?#])"#, options: .regularExpression) != nil {
      return false
    }
    if lower.range(of: #"\.(?:m3u8?|mp4|flv|mkv|mpd|webm|m4v|mov)(?:$|[?#])"#, options: .regularExpression) != nil {
      return true
    }
    return lower.range(of: #"[?&](?:type|format|mime)=[^&#]*(?:m3u8|mp4|flv|mpegurl|video)"#, options: .regularExpression) != nil
  }

  private func start() {
    let config = WKWebViewConfiguration()
    let store = WKWebsiteDataStore.nonPersistent()
    self.dataStore = store
    config.websiteDataStore = store
    #if os(iOS)
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = .all
    #elseif os(macOS)
    config.mediaTypesRequiringUserActionForPlayback = .all
    #endif

    let contentController = WKUserContentController()
    contentController.add(WeakSnifferScriptHandler(self), name: "marcoSniffer")
    contentController.addUserScript(
      WKUserScript(source: Self.hookScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    )
    config.userContentController = contentController

    let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720), configuration: config)
    wv.navigationDelegate = self
    wv.uiDelegate = self
    wv.customUserAgent = effectiveUa
    self.webView = wv

    var req = URLRequest(url: targetUrl, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12.0)
    for (k, v) in headers {
      if k.lowercased() == "user-agent" { continue }
      req.setValue(v, forHTTPHeaderField: k)
    }
    wv.load(req)

    let boundedMs = min(max(timeoutMs, 2000), 20000)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(boundedMs)) { [weak self] in
      self?.finish(with: nil)
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    let scheme = (url.scheme ?? "").lowercased()
    if scheme == "rtmp" || scheme == "rtsp" {
      completeWithMedia(url: url, referer: webView.url?.absoluteString ?? targetUrl.absoluteString)
      decisionHandler(.cancel)
      return
    }
    guard ["http", "https", "about", "blob", "data"].contains(scheme) else {
      decisionHandler(.cancel)
      return
    }
    if (scheme == "http" || scheme == "https") && Self.looksLikePlayableMedia(url.absoluteString) {
      let ref = navigationAction.request.value(forHTTPHeaderField: "Referer") ?? webView.url?.absoluteString ?? targetUrl.absoluteString
      completeWithMedia(url: url, referer: ref)
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    if let url = navigationResponse.response.url,
       let scheme = url.scheme?.lowercased(),
       (scheme == "http" || scheme == "https") {
      let mime = (navigationResponse.response.mimeType ?? "").lowercased()
      if mime.contains("mpegurl") || mime.hasPrefix("video/") || mime.contains("dash+xml") || Self.looksLikePlayableMedia(url.absoluteString) {
        completeWithMedia(url: url, referer: webView.url?.absoluteString ?? targetUrl.absoluteString)
        decisionHandler(.cancel)
        return
      }
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    return nil
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.name == "marcoSniffer", !completed else { return }
    guard let body = message.body as? [String: Any],
          let rawUrl = body["url"] as? String,
          let mediaUrl = URL(string: rawUrl),
          let scheme = mediaUrl.scheme?.lowercased(),
          ["http", "https", "rtmp", "rtsp"].contains(scheme),
          mediaUrl.host != nil,
          Self.looksLikePlayableMedia(mediaUrl.absoluteString) else {
      return
    }
    let pageUrl = (body["pageUrl"] as? String) ?? ""
    let referer = (pageUrl.hasPrefix("http://") || pageUrl.hasPrefix("https://"))
      ? pageUrl
      : (webView?.url?.absoluteString ?? targetUrl.absoluteString)
    completeWithMedia(url: mediaUrl, referer: referer)
  }

  private func completeWithMedia(url: URL, referer: String) {
    guard !completed else { return }
    let mediaHost = (url.host ?? "").lowercased()
    guard let store = dataStore?.httpCookieStore else {
      finish(with: [
        "url": url.absoluteString,
        "headers": ["Referer": referer, "User-Agent": effectiveUa]
      ])
      return
    }
    store.getAllCookies { [weak self] cookies in
      guard let self = self, !self.completed else { return }
      let now = Date()
      var cookiePairs: [String] = []
      for c in cookies {
        if c.value.isEmpty { continue }
        if let exp = c.expiresDate, exp <= now { continue }
        let rawDom = c.domain.lowercased()
        let cleanDom = rawDom.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let matched = rawDom.hasPrefix(".")
          ? (mediaHost == cleanDom || mediaHost.hasSuffix("." + cleanDom))
          : (mediaHost == cleanDom)
        if matched {
          cookiePairs.append("\(c.name)=\(c.value)")
        }
      }
      var outHeaders: [String: String] = [
        "Referer": referer,
        "User-Agent": self.effectiveUa
      ]
      if !cookiePairs.isEmpty {
        outHeaders["Cookie"] = cookiePairs.joined(separator: "; ")
      }
      self.finish(with: [
        "url": url.absoluteString,
        "headers": outHeaders
      ])
    }
  }

  private func finish(with payload: [String: Any]?) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.finish(with: payload)
      }
      return
    }
    guard !completed else { return }
    completed = true
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "marcoSniffer")
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView?.uiDelegate = nil
    webView = nil
    dataStore = nil
    let callback = completion
    completion = nil
    Self.activeSniffers.remove(self)
    callback?(payload)
  }
}
'''

def _png_dimensions(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if len(data) >= 24 and data[:8] == b"\x89PNG\r\n\x1a\n":
        w, h = struct.unpack(">II", data[16:24])
        if w > 0 and h > 0:
            return w, h
    return 1024, 1024

def _resolve_iconset_match(source_dir: Path, filename: str, w: int, h: int, contents_map: dict[str, str]) -> Path | None:
    if filename in contents_map:
        candidate = source_dir / contents_map[filename]
        if candidate.exists() and _png_dimensions(candidate) == (w, h):
            return candidate
    for name in (f"icon_{w}x{h}.png", f"icon_{w // 2}x{h // 2}@2x.png" if w % 2 == 0 and h % 2 == 0 else ""):
        if name:
            candidate = source_dir / name
            if candidate.exists() and _png_dimensions(candidate) == (w, h):
                return candidate
    return None

def _replace_xcassets_icons(appiconset_dir: Path, source: Path) -> None:
    if not appiconset_dir.exists() or not source.exists():
        return
    contents_map: dict[str, str] = {}
    contents_json = appiconset_dir / "Contents.json"
    if source.is_dir() and contents_json.exists():
        try:
            meta = json.loads(contents_json.read_text(encoding="utf-8"))
            for item in meta.get("images", []):
                fname = item.get("filename")
                size = item.get("size")
                scale = item.get("scale")
                if fname and size:
                    contents_map[fname] = f"icon_{size}@{scale}.png" if scale == "2x" else f"icon_{size}.png"
        except Exception:
            contents_map = {}
    fallback = (source / "icon_512x512@2x.png") if source.is_dir() else source
    sips = shutil.which("sips")
    for png_file in appiconset_dir.glob("*.png"):
        w, h = _png_dimensions(png_file)
        if source.is_dir():
            matched = _resolve_iconset_match(source, png_file.name, w, h, contents_map)
            if matched is not None:
                shutil.copy2(matched, png_file)
                continue
        if not fallback.exists():
            continue
        shutil.copy2(fallback, png_file)
        if sips:
            subprocess.run(
                [sips, "-z", str(h), str(w), str(png_file)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

def _write_windows_ico(ico_path: Path, source_png: Path) -> None:
    if not ico_path.parent.exists():
        return
    # Multi-resolution transparent assets prevent a gray square and poor shell scaling.
    frames = []
    for size in (16, 20, 24, 32, 40, 48, 64, 128, 256):
        png = ROOT / "brand" / "windows" / f"{size}.png"
        if _png_dimensions(png) != (size, size):
            raise ValueError("Invalid Windows icon frame")
        frames.append((size, png.read_bytes()))
    offset = 6 + 16 * len(frames)
    directory = bytearray(struct.pack("<HHH", 0, 1, len(frames)))
    payload = bytearray()
    for size, data in frames:
        directory.extend(struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(data), offset))
        payload.extend(data)
        offset += len(data)
    ico_path.write_bytes(directory + payload)


def _upgrade_macos_media_kit_mpv_v073() -> None:
    """Upgrade pub-cached media_kit_libs_macos_video Makefile from v0.6.0 to v0.7.3 on macOS.

    media_kit_libs_macos_video 1.1.4 (latest on pub.dev) bundles libmpv-darwin-build v0.6.0,
    whose Avcodec.framework omits FFmpeg's pgssub decoder, preventing Blu-ray PGS subtitles
    from rendering on macOS. Official upstream v0.7.3 enables --enable-decoder=pgssub while
    retaining -mmacosx-version-min=10.9 and identical mpv 0.36.0 / FFmpeg 6.0 ABI.
    """
    if sys.platform != "darwin":
        return
    pkg_cfg = ROOT / ".dart_tool" / "package_config.json"
    if not pkg_cfg.is_file():
        return
    try:
        cfg = json.loads(pkg_cfg.read_text(encoding="utf-8"))
    except Exception:
        return
    target_ver = "v0.7.3"
    target_sha = "2e58ac66b0ea875239bf4db29b3ef2100a719df1d61fa1e780c38d651d4c9f27"
    for pkg in cfg.get("packages", []):
        if pkg.get("name") != "media_kit_libs_macos_video":
            continue
        root_uri = pkg.get("rootUri", "")
        if not root_uri:
            continue
        if root_uri.startswith("file://"):
            pkg_root = Path(unquote(urlparse(root_uri).path))
        else:
            pkg_root = (pkg_cfg.parent / root_uri).resolve()
        macos_dir = pkg_root / "macos"
        makefile = macos_dir / "Makefile"
        if not makefile.is_file():
            return
        src = makefile.read_text(encoding="utf-8")
        if f"MPV_XCFRAMEWORKS_VERSION={target_ver}" in src and target_sha in src:
            print(f"media_kit_libs_macos_video Makefile already at libmpv {target_ver}: {makefile}", flush=True)
            return
        updated = re.sub(
            r"^MPV_XCFRAMEWORKS_VERSION=.*$",
            f"MPV_XCFRAMEWORKS_VERSION={target_ver}",
            src,
            flags=re.MULTILINE,
        )
        updated = re.sub(
            r"^MPV_XCFRAMEWORKS_SHA256SUM=.*$",
            f"MPV_XCFRAMEWORKS_SHA256SUM={target_sha}",
            updated,
            flags=re.MULTILINE,
        )
        if updated != src:
            makefile.write_text(updated, encoding="utf-8")
            fw_dir = macos_dir / "Frameworks"
            if fw_dir.is_dir():
                for child in fw_dir.iterdir():
                    if child.name.endswith(".xcframework") or child.name == ".symlinks":
                        if child.is_dir() and not child.is_symlink():
                            shutil.rmtree(child)
                        else:
                            child.unlink(missing_ok=True)
            print(
                f"Upgraded media_kit_libs_macos_video Makefile to libmpv {target_ver} (pgssub enabled): {makefile}",
                flush=True,
            )
        return


MACOS_MEDIA_KIT_VSYNC_PATCH_MARKER = "// MARCO_MOVIE_VSYNC_PACED_V1"
MACOS_VIDEO_OUTPUT_VSYNC_MARKER = "// MARCO_MOVIE_VSYNC_VIDEO_OUTPUT_V1"

MACOS_TEXTURE_HW_VSYNC_SWIFT = r'''// MARCO_MOVIE_VSYNC_PACED_V1
import Cocoa
import CoreVideo
import FlutterMacOS
import OpenGL.GL
import OpenGL.GL3

public class TextureHW: NSObject, FlutterTexture, ResizableTextureProtocol {
  public typealias UpdateCallback = () -> Void

  private static let displayChangedNotification = Notification.Name(
    "MarcoMovieDisplayChanged"
  )
  private static let maxIdleTicksBeforeStop = 180

  private let handle: OpaquePointer
  private let updateCallback: UpdateCallback
  private let pixelFormat: CGLPixelFormatObj
  private let context: CGLContextObj
  private let textureCache: CVOpenGLTextureCache
  private var renderContext: OpaquePointer?
  private var textureContexts = SwappableObjectManager<TextureGLContext>(
    objects: [],
    skipCheckArgs: true
  )

  private let vsyncLock = NSLock()
  private var displayLink: CVDisplayLink?
  private var displayObserver: NSObjectProtocol?
  private var vsyncPaced: Bool = false
  private var hasPendingUpdate: Bool = false
  private var tickInFlight: Bool = false
  private var idleTickCount: Int = 0
  private var disposed: Bool = false
  public private(set) var lastRenderProducedFrame: Bool = true

  init(
    handle: OpaquePointer,
    updateCallback: @escaping UpdateCallback
  ) {
    self.handle = handle
    self.updateCallback = updateCallback
    self.pixelFormat = OpenGLHelpers.createPixelFormat()
    self.context = OpenGLHelpers.createContext(pixelFormat)
    self.textureCache = OpenGLHelpers.createTextureCache(context, pixelFormat)

    super.init()

    self.initMPV()
  }

  deinit {
    stopAndReleaseDisplayLink()
    disposePixelBuffer()
    disposeMPV()
    OpenGLHelpers.deleteTextureCache(textureCache)
    OpenGLHelpers.deletePixelFormat(pixelFormat)

    // Deleting the context may cause potential RAM or VRAM memory leaks, as it
    // is used in the `deinit` method of the `TextureGLContext`.
    OpenGLHelpers.deleteContext(context)
  }

  public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    let textureContext = textureContexts.current
    if textureContext == nil {
      return nil
    }

    return Unmanaged.passRetained(textureContext!.pixelBuffer)
  }

  private func setupDisplayLink() -> Bool {
    var link: CVDisplayLink?
    var status: CVReturn = kCVReturnError
    if let screen = NSScreen.main ?? NSScreen.screens.first,
       let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
      let displayID = CGDirectDisplayID(num.uint32Value)
      status = CVDisplayLinkCreateWithCGDisplay(displayID, &link)
    }
    if status != kCVReturnSuccess || link == nil {
      status = CVDisplayLinkCreateWithActiveCGDisplays(&link)
    }
    guard status == kCVReturnSuccess, let created = link else {
      return false
    }

    let cbStatus = CVDisplayLinkSetOutputCallback(
      created,
      { (_, _, _, _, _, userInfo) -> CVReturn in
        guard let userInfo = userInfo else {
          return kCVReturnSuccess
        }
        let that = Unmanaged<TextureHW>.fromOpaque(userInfo).takeUnretainedValue()
        that.handleDisplayLinkTick()
        return kCVReturnSuccess
      },
      Unmanaged.passUnretained(self).toOpaque()
    )
    guard cbStatus == kCVReturnSuccess else {
      return false
    }

    vsyncLock.lock()
    self.displayLink = created
    self.vsyncPaced = true
    vsyncLock.unlock()

    displayObserver = NotificationCenter.default.addObserver(
      forName: Self.displayChangedNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard let self = self,
            let num = note.userInfo?["displayID"] as? NSNumber else {
        return
      }
      self.updateDisplayLinkDisplay(CGDirectDisplayID(num.uint32Value))
    }
    return true
  }

  private func updateDisplayLinkDisplay(_ displayID: CGDirectDisplayID) {
    vsyncLock.lock()
    let link = displayLink
    let isDisposed = disposed
    vsyncLock.unlock()
    guard !isDisposed, let link = link else { return }
    CVDisplayLinkSetCurrentCGDisplay(link, displayID)
  }

  private func stopAndReleaseDisplayLink() {
    vsyncLock.lock()
    disposed = true
    let link = displayLink
    displayLink = nil
    let observer = displayObserver
    displayObserver = nil
    vsyncLock.unlock()

    if let observer = observer {
      NotificationCenter.default.removeObserver(observer)
    }
    if let link = link {
      if CVDisplayLinkIsRunning(link) {
        CVDisplayLinkStop(link)
      }
    }
  }

  private func scheduleVsyncWake() {
    vsyncLock.lock()
    if disposed {
      vsyncLock.unlock()
      return
    }
    hasPendingUpdate = true
    idleTickCount = 0
    let link = displayLink
    vsyncLock.unlock()

    if let link = link, !CVDisplayLinkIsRunning(link) {
      CVDisplayLinkStart(link)
    }
  }

  private func handleDisplayLinkTick() {
    vsyncLock.lock()
    if disposed {
      let link = displayLink
      vsyncLock.unlock()
      if let link = link, CVDisplayLinkIsRunning(link) {
        CVDisplayLinkStop(link)
      }
      return
    }
    if tickInFlight {
      vsyncLock.unlock()
      return
    }
    if !hasPendingUpdate && idleTickCount >= Self.maxIdleTicksBeforeStop {
      let link = displayLink
      vsyncLock.unlock()
      if let link = link, CVDisplayLinkIsRunning(link) {
        CVDisplayLinkStop(link)
      }
      return
    }
    tickInFlight = true
    hasPendingUpdate = false
    vsyncLock.unlock()

    updateCallback()
  }

  public func endVsyncTick() {
    vsyncLock.lock()
    tickInFlight = false
    vsyncLock.unlock()
  }

  public func drainPendingUpdateWithoutRender() {
    guard vsyncPaced, let rc = renderContext else {
      return
    }
    CGLSetCurrentContext(context)
    defer {
      CGLSetCurrentContext(nil)
    }
    let flags = mpv_render_context_update(rc)
    vsyncLock.lock()
    if (flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue)) != 0 {
      idleTickCount = 0
    } else {
      idleTickCount += 1
    }
    vsyncLock.unlock()
    lastRenderProducedFrame = false
  }

  private func initMPV() {
    CGLSetCurrentContext(context)
    defer {
      OpenGLHelpers.checkError("initMPV")
      CGLSetCurrentContext(nil)
    }

    let api = UnsafeMutableRawPointer(
      mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String
    )
    var procAddress = mpv_opengl_init_params(
      get_proc_address: {
        (ctx, name) in
        return TextureHW.getProcAddress(ctx, name)
      },
      get_proc_address_ctx: nil
    )

    let enableVsync = setupDisplayLink()
    setenv("MARCO_MPV_VSYNC_PACED", enableVsync ? "1" : "0", 1)

    if enableVsync {
      var advancedControl: Int32 = 1
      withUnsafeMutableBytes(of: &procAddress) { procBytes in
        withUnsafeMutablePointer(to: &advancedControl) { advPtr in
          var params: [mpv_render_param] = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
            mpv_render_param(
              type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
              data: procBytes.baseAddress.map { UnsafeMutableRawPointer($0) }
            ),
            mpv_render_param(
              type: MPV_RENDER_PARAM_ADVANCED_CONTROL,
              data: UnsafeMutableRawPointer(advPtr)
            ),
            mpv_render_param(),
          ]
          MPVHelpers.checkError(
            mpv_render_context_create(&renderContext, handle, &params)
          )
        }
      }

      mpv_render_context_set_update_callback(
        renderContext,
        { (ctx) in
          guard let ctx = ctx else { return }
          let that = Unmanaged<TextureHW>.fromOpaque(ctx).takeUnretainedValue()
          that.scheduleVsyncWake()
        },
        UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
      )
      scheduleVsyncWake()
    } else {
      var params: [mpv_render_param] = withUnsafeMutableBytes(of: &procAddress) {
        procBytes in
        return [
          mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
          mpv_render_param(
            type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
            data: procBytes.baseAddress.map {
              UnsafeMutableRawPointer($0)
            }
          ),
          mpv_render_param(),
        ]
      }

      MPVHelpers.checkError(
        mpv_render_context_create(&renderContext, handle, &params)
      )

      mpv_render_context_set_update_callback(
        renderContext,
        { (ctx) in
          let that = unsafeBitCast(ctx, to: TextureHW.self)
          DispatchQueue.main.async {
            that.updateCallback()
          }
        },
        UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
      )
    }
  }

  private func disposeMPV() {
    CGLSetCurrentContext(context)
    defer {
      OpenGLHelpers.checkError("disposeMPV")
      CGLSetCurrentContext(nil)
    }

    mpv_render_context_set_update_callback(renderContext, nil, nil)
    mpv_render_context_free(renderContext)
    renderContext = nil
  }

  public func resize(_ size: CGSize) {
    if size.width == 0 || size.height == 0 {
      return
    }

    NSLog("TextureGL: resize: \(size.width)x\(size.height)")
    createPixelBuffer(size)
  }

  private func createPixelBuffer(_ size: CGSize) {
    disposePixelBuffer()

    textureContexts.reinit(
      objects: [
        TextureGLContext(
          context: context,
          textureCache: textureCache,
          size: size
        ),
        TextureGLContext(
          context: context,
          textureCache: textureCache,
          size: size
        ),
        TextureGLContext(
          context: context,
          textureCache: textureCache,
          size: size
        ),
      ],
      skipCheckArgs: true
    )
  }

  private func disposePixelBuffer() {
    textureContexts.reinit(objects: [], skipCheckArgs: true)
  }

  public func render(_ size: CGSize) {
    guard let rc = renderContext else {
      lastRenderProducedFrame = false
      return
    }

    CGLSetCurrentContext(context)
    defer {
      OpenGLHelpers.checkError("render")
      CGLSetCurrentContext(nil)
    }

    if vsyncPaced {
      let flags = mpv_render_context_update(rc)
      if (flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue)) == 0 {
        vsyncLock.lock()
        idleTickCount += 1
        vsyncLock.unlock()
        lastRenderProducedFrame = false
        return
      }
      vsyncLock.lock()
      idleTickCount = 0
      vsyncLock.unlock()
    }

    let textureContext = textureContexts.nextAvailable()
    if textureContext == nil {
      lastRenderProducedFrame = false
      return
    }

    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), textureContext!.frameBuffer)
    defer {
      glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
    }

    var fbo = mpv_opengl_fbo(
      fbo: Int32(textureContext!.frameBuffer),
      w: Int32(size.width),
      h: Int32(size.height),
      internal_format: 0
    )

    if vsyncPaced {
      var blockForTargetTime: Int32 = 0
      withUnsafeMutablePointer(to: &fbo) { fboPtr in
        withUnsafeMutablePointer(to: &blockForTargetTime) { blockPtr in
          var params: [mpv_render_param] = [
            mpv_render_param(
              type: MPV_RENDER_PARAM_OPENGL_FBO,
              data: UnsafeMutableRawPointer(fboPtr)
            ),
            mpv_render_param(
              type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME,
              data: UnsafeMutableRawPointer(blockPtr)
            ),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
          ]
          mpv_render_context_render(rc, &params)
        }
      }
    } else {
      withUnsafeMutablePointer(to: &fbo) { fboPtr in
        var params: [mpv_render_param] = [
          mpv_render_param(
            type: MPV_RENDER_PARAM_OPENGL_FBO,
            data: UnsafeMutableRawPointer(fboPtr)
          ),
          mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]
        mpv_render_context_render(rc, &params)
      }
    }

    glFlush()

    textureContexts.pushAsReady(textureContext!)
    if vsyncPaced {
      mpv_render_context_report_swap(rc)
    }
    lastRenderProducedFrame = true
  }

  static private func getProcAddress(
    _ ctx: UnsafeMutableRawPointer?,
    _ name: UnsafePointer<Int8>?
  ) -> UnsafeMutableRawPointer? {
    let symbol: CFString = CFStringCreateWithCString(
      kCFAllocatorDefault,
      name,
      kCFStringEncodingASCII
    )
    let indentifier = CFBundleGetBundleWithIdentifier(
      "com.apple.opengl" as CFString
    )
    let addr = CFBundleGetFunctionPointerForName(indentifier, symbol)

    if addr == nil {
      NSLog("Cannot get OpenGL function pointer!")
    }
    return addr
  }
}
'''


def patch_macos_media_kit_video_vsync(plugin_macos_dir: Path) -> bool:
    """Idempotently patch media_kit_video's macOS TextureHW & VideoOutput to use
    CVDisplayLink + MPV_RENDER_PARAM_ADVANCED_CONTROL + mpv_render_context_update
    + mpv_render_context_report_swap for tear-free, judder-free display sync.
    """
    texture_hw = plugin_macos_dir / "Classes" / "plugin" / "TextureHW.swift"
    video_output = plugin_macos_dir / "Classes" / "plugin" / "common" / "VideoOutput.swift"
    if not texture_hw.is_file() or not video_output.is_file():
        return False

    changed = False
    hw_src = texture_hw.read_text(encoding="utf-8")
    if MACOS_MEDIA_KIT_VSYNC_PATCH_MARKER not in hw_src or hw_src != MACOS_TEXTURE_HW_VSYNC_SWIFT:
        texture_hw.write_text(MACOS_TEXTURE_HW_VSYNC_SWIFT, encoding="utf-8")
        changed = True

    vo_src = video_output.read_text(encoding="utf-8")
    if MACOS_VIDEO_OUTPUT_VSYNC_MARKER not in vo_src:
        patched_vo = f"{MACOS_VIDEO_OUTPUT_VSYNC_MARKER}\n{vo_src}"
        patched_vo = patched_vo.replace(
            "  private var texture: ResizableTextureProtocol!",
            "  private var texture: ResizableTextureProtocol!\n  private weak var hwTexture: TextureHW?",
            1,
        )
        patched_vo = patched_vo.replace(
            "    if enableHardwareAcceleration {\n"
            "      texture = SafeResizableTexture(\n"
            "        TextureHW(\n"
            "          handle: handle,\n"
            "          // Use `weak self` to prevent memory leaks\n"
            "          updateCallback: { [weak self]() in\n"
            "            guard let that = self else {\n"
            "              return\n"
            "            }\n"
            "            that.updateCallback()\n"
            "          }\n"
            "        )\n"
            "      )\n"
            "    }",
            "    if enableHardwareAcceleration {\n"
            "      let hw = TextureHW(\n"
            "        handle: handle,\n"
            "        // Use `weak self` to prevent memory leaks\n"
            "        updateCallback: { [weak self]() in\n"
            "          guard let that = self else {\n"
            "            return\n"
            "          }\n"
            "          that.updateCallback()\n"
            "        }\n"
            "      )\n"
            "      self.hwTexture = hw\n"
            "      texture = SafeResizableTexture(hw)\n"
            "    }",
            1,
        )
        patched_vo = patched_vo.replace(
            "  private func _updateCallback() {\n"
            "    let size = videoSize\n\n"
            "    if size.width == 0 || size.height == 0 {\n"
            "      return\n"
            "    }",
            "  private func _updateCallback() {\n"
            "    defer {\n"
            "      hwTexture?.endVsyncTick()\n"
            "    }\n"
            "    let size = videoSize\n\n"
            "    if size.width == 0 || size.height == 0 {\n"
            "      hwTexture?.drainPendingUpdateWithoutRender()\n"
            "      return\n"
            "    }",
            1,
        )
        patched_vo = patched_vo.replace(
            "    texture.render(size)\n"
            "    DispatchQueue.main.sync { [weak self] in",
            "    texture.render(size)\n"
            "    if let hw = hwTexture, !hw.lastRenderProducedFrame {\n"
            "      return\n"
            "    }\n"
            "    if disposed {\n"
            "      return\n"
            "    }\n"
            "    DispatchQueue.main.sync { [weak self] in",
            1,
        )
        if "hwTexture?.endVsyncTick()" not in patched_vo or "lastRenderProducedFrame" not in patched_vo:
            raise RuntimeError(f"Failed to patch media_kit_video VideoOutput.swift cleanly: {video_output}")
        video_output.write_text(patched_vo, encoding="utf-8")
        changed = True
    return changed


def _upgrade_macos_media_kit_video_vsync() -> None:
    if sys.platform != "darwin":
        return
    candidates: list[Path] = []
    symlink_dir = ROOT / "macos" / "Flutter" / "ephemeral" / ".symlinks" / "plugins" / "media_kit_video" / "macos"
    if symlink_dir.is_dir():
        candidates.append(symlink_dir.resolve())
    pkg_cfg = ROOT / ".dart_tool" / "package_config.json"
    if pkg_cfg.is_file():
        try:
            cfg = json.loads(pkg_cfg.read_text(encoding="utf-8"))
            for pkg in cfg.get("packages", []):
                if pkg.get("name") != "media_kit_video":
                    continue
                root_uri = pkg.get("rootUri", "")
                if not root_uri:
                    continue
                if root_uri.startswith("file://"):
                    pkg_root = Path(unquote(urlparse(root_uri).path))
                else:
                    pkg_root = (pkg_cfg.parent / root_uri).resolve()
                macos_dir = (pkg_root / "macos").resolve()
                if macos_dir.is_dir() and macos_dir not in candidates:
                    candidates.append(macos_dir)
        except Exception:
            pass
    for macos_dir in candidates:
        if patch_macos_media_kit_video_vsync(macos_dir):
            print(f"Patched media_kit_video macOS CVDisplayLink vsync render loop: {macos_dir}", flush=True)


def main() -> None:
    subprocess.run([sys.executable, str(REPO_ROOT / 'scripts/prepare_python_html.py'), '--check'], check=True)
    subprocess.run([sys.executable, str(REPO_ROOT / 'scripts/prepare_python_modules.py'), '--check'], check=True)
    src = ROOT / "src"
    if src.exists():
        raise RuntimeError(
            "flutter/src has been migrated to flutter/lib. "
            "Please delete flutter/src to prevent accidental divergence."
        )
    # Bundle user's brand logo into flutter/assets/logo_mark.png
    assets_dir = ROOT / "assets"
    assets_dir.mkdir(parents=True, exist_ok=True)
    shutil.copytree(REPO_ROOT / 'shared/catpaw', assets_dir / 'catpaw', dirs_exist_ok=True)
    python_host = REPO_ROOT / "shared/script-host/python-host"
    shutil.copytree(python_host, assets_dir / "python-host", dirs_exist_ok=True)
    (assets_dir / 'js-host').mkdir(parents=True, exist_ok=True)
    for name in ('module-interop.js', 'catvod.mjs', 'crypto-js.js', 'crypto.LICENSE'):
        shutil.copyfile(REPO_ROOT / 'shared/script-host/js-host' / name,
                        assets_dir / 'js-host' / name)
    if LOGO_MARK.exists():
        shutil.copy2(LOGO_MARK, assets_dir / "logo_mark.png")
    badge_rules = REPO_ROOT / "shared" / "ui-spec" / "badge-rules.json"
    if badge_rules.exists():
        ui_spec_dir = assets_dir / "ui-spec"
        ui_spec_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(badge_rules, ui_spec_dir / "badge-rules.json")
    widget_test = ROOT / "test" / "widget_test.dart"
    if widget_test.exists():
        widget_test.unlink()
    # macOS entitlements, deployment target, app icon, and native dark full-size window
    macos_runner = ROOT / "macos" / "Runner"
    if macos_runner.exists():
        _replace_xcassets_icons(
            macos_runner / "Assets.xcassets" / "AppIcon.appiconset",
            MACOS_ICON_DIR if MACOS_ICON_DIR.exists() else (OPAQUE_ICON if OPAQUE_ICON.exists() else LOGO_MARK),
        )
        for ent in macos_runner.glob("*.entitlements"):
            text = ent.read_text(encoding="utf-8")
            if "com.apple.security.network.server" not in text:
                text = text.replace(
                    "</dict>",
                    "  <key>com.apple.security.network.server</key>\n  <true/>\n</dict>",
                )
            if "com.apple.security.network.client" not in text:
                text = text.replace(
                    "</dict>",
                    "  <key>com.apple.security.network.client</key>\n  <true/>\n</dict>",
                )
            # Offline downloads are saved to ~/Downloads/Marco Movie
            if "com.apple.security.files.downloads.read-write" not in text:
                text = text.replace(
                    "</dict>",
                    "  <key>com.apple.security.files.downloads.read-write</key>\n  <true/>\n</dict>",
                )
            # NSOpenPanel / NSSavePanel require user-selected file access under App Sandbox
            if "com.apple.security.files.user-selected.read-write" not in text:
                text = text.replace(
                    "</dict>",
                    "  <key>com.apple.security.files.user-selected.read-write</key>\n  <true/>\n</dict>",
                )
            # Release distributions must never carry the debug get-task-allow entitlement.
            if ent.name == "Release.entitlements":
                text = re.sub(
                    r"\s*<key>com\.apple\.security\.get-task-allow</key>\s*<(?:true|false)\s*/>\s*",
                    "\n",
                    text,
                )
            ent.write_text(text, encoding="utf-8")
        app_info_xcconfig = macos_runner / "Configs" / "AppInfo.xcconfig"
        if app_info_xcconfig.exists():
            cfg = app_info_xcconfig.read_text(encoding="utf-8")
            cfg = re.sub(
                r"(?m)^PRODUCT_NAME\s*=\s*.*$",
                "PRODUCT_NAME = MarcoMovie",
                cfg,
            )
            app_info_xcconfig.write_text(cfg, encoding="utf-8")
        main_menu_xib = macos_runner / "Base.lproj" / "MainMenu.xib"
        if main_menu_xib.exists():
            xib_text = main_menu_xib.read_text(encoding="utf-8")
            xib_text = xib_text.replace("APP_NAME", "MarcoMovie").replace("marco_movie", "MarcoMovie")
            main_menu_xib.write_text(xib_text, encoding="utf-8")
        info_plist = macos_runner / "Info.plist"
        if info_plist.exists():
            text = info_plist.read_text(encoding="utf-8")
            text = text.replace("<string>marco_movie</string>", "<string>MarcoMovie</string>")
            if "<key>CFBundleDisplayName</key>" not in text:
                text = re.sub(
                    r"</dict>\s*</plist>",
                    "  <key>CFBundleDisplayName</key>\n"
                    "  <string>MarcoMovie</string>\n</dict>\n</plist>",
                    text,
                    count=1,
                )
            if "NSLocalNetworkUsageDescription" not in text:
                text = text.replace("</dict>\n</plist>",
                    "  <key>NSLocalNetworkUsageDescription</key>\n"
                    "  <string>连接你添加的局域网 Emby 服务器及片源。</string>\n</dict>\n</plist>")
            if "NSAppTransportSecurity" not in text:
                text = text.replace(
                    "</dict>",
                    "  <key>NSAppTransportSecurity</key>\n  <dict>\n    <key>NSAllowsArbitraryLoads</key>\n    <true/>\n  </dict>\n</dict>",
                    1,
                )
            info_plist.write_text(text, encoding="utf-8")
        window_swift = macos_runner / "MainFlutterWindow.swift"
        if window_swift.exists():
            swift_text = window_swift.read_text(encoding="utf-8")
            if "import WebKit" not in swift_text and "import FlutterMacOS" in swift_text:
                swift_text = swift_text.replace("import FlutterMacOS", "import FlutterMacOS\nimport WebKit", 1)
            if "import CoreVideo" not in swift_text and "import FlutterMacOS" in swift_text:
                swift_text = swift_text.replace("import FlutterMacOS", "import FlutterMacOS\nimport CoreVideo", 1)
            if "playbackActivity" not in swift_text:
                swift_text = swift_text.replace(
                    "class MainFlutterWindow: NSWindow {",
                    "class MainFlutterWindow: NSWindow {\n"
                    "  private var playbackActivity: NSObjectProtocol?",
                    1,
                )
            if "private var marcoWindowObservers:" not in swift_text:
                anchor = (
                    "  private var playbackActivity: NSObjectProtocol?"
                    if "  private var playbackActivity: NSObjectProtocol?" in swift_text
                    else "class MainFlutterWindow: NSWindow {"
                )
                swift_text = swift_text.replace(
                    anchor,
                    anchor + "\n"
                    "  private var marcoWindowObservers: [NSObjectProtocol] = []\n"
                    "  private var marcoInFullscreenTransition = false\n"
                    "  private var marcoIsMiniaturizing = false\n"
                    "  private var marcoIsClosing = false\n"
                    "  private var marcoRestoredFromSaved = false\n"
                    "  private var marcoLastNormalFrame: NSRect?\n\n"
                    "  deinit {\n"
                    "    for observer in marcoWindowObservers {\n"
                    "      NotificationCenter.default.removeObserver(observer)\n"
                    "    }\n"
                    "    marcoWindowObservers.removeAll()\n"
                    "  }",
                    1,
                )
            if "private var marcoWindowChannel:" not in swift_text and "private var marcoLastNormalFrame: NSRect?" in swift_text:
                swift_text = swift_text.replace(
                    "  private var marcoLastNormalFrame: NSRect?",
                    "  private var marcoLastNormalFrame: NSRect?\n"
                    "  private var marcoWindowChannel: FlutterMethodChannel?",
                    1,
                )
            if "marco_movie/wakelock" not in swift_text and "RegisterGeneratedPlugins(registry: flutterViewController)" in swift_text:
                swift_text = swift_text.replace(
                    "RegisterGeneratedPlugins(registry: flutterViewController)",
                    "RegisterGeneratedPlugins(registry: flutterViewController)\n"
                    "    let wakelockChannel = FlutterMethodChannel(name: \"marco_movie/wakelock\", binaryMessenger: flutterViewController.engine.binaryMessenger)\n"
                    "    wakelockChannel.setMethodCallHandler { [weak self] call, result in\n"
                    "      if call.method == \"setEnabled\", let enabled = call.arguments as? Bool {\n"
                    "        if enabled {\n"
                    "          if self?.playbackActivity == nil {\n"
                    "            self?.playbackActivity = ProcessInfo.processInfo.beginActivity(options: .idleDisplaySleepDisabled, reason: \"Marco Movie Video Playback\")\n"
                    "          }\n"
                    "        } else if let token = self?.playbackActivity {\n"
                    "          ProcessInfo.processInfo.endActivity(token)\n"
                    "          self?.playbackActivity = nil\n"
                    "        }\n"
                    "        result(nil)\n"
                    "      } else {\n"
                    "        result(FlutterMethodNotImplemented)\n"
                    "      }\n"
                    "    }",
                    1,
                )
            if "marco_movie/macos_window" not in swift_text and "RegisterGeneratedPlugins(registry: flutterViewController)" in swift_text:
                swift_text = swift_text.replace(
                    "RegisterGeneratedPlugins(registry: flutterViewController)",
                    "RegisterGeneratedPlugins(registry: flutterViewController)"
                    + MACOS_WINDOW_CHANNEL_SNIPPET,
                    1,
                )
            if "marco_movie/web_sniffer" not in swift_text and "RegisterGeneratedPlugins(registry: flutterViewController)" in swift_text:
                swift_text = swift_text.replace(
                    "RegisterGeneratedPlugins(registry: flutterViewController)",
                    "RegisterGeneratedPlugins(registry: flutterViewController)"
                    + MACOS_WEB_SNIFFER_CHANNEL_SNIPPET,
                    1,
                )
            if "self.marcoRestoreInitialFrame()" not in swift_text:
                if "titlebarAppearsTransparent" in swift_text:
                    swift_text = re.sub(
                        r"self\.titleVisibility = \.hidden.*?super\.awakeFromNib\(\)",
                        "self.isRestorable = false\n"
                        "    self.titleVisibility = .hidden\n"
                        "    self.titlebarAppearsTransparent = true\n"
                        "    self.styleMask.insert(.fullSizeContentView)\n"
                        "    self.minSize = NSSize(width: 720, height: 520)\n"
                        "    self.marcoRestoreInitialFrame()\n"
                        "    super.awakeFromNib()\n"
                        "    self.marcoEnsureWindowChromeVisible()\n"
                        "    self.marcoInstallWindowObservers()",
                        swift_text,
                        count=1,
                        flags=re.DOTALL,
                    )
                else:
                    swift_text = swift_text.replace(
                        "super.awakeFromNib()",
                        "self.isRestorable = false\n"
                        "    self.titleVisibility = .hidden\n"
                        "    self.titlebarAppearsTransparent = true\n"
                        "    self.styleMask.insert(.fullSizeContentView)\n"
                        "    self.minSize = NSSize(width: 720, height: 520)\n"
                        "    self.marcoRestoreInitialFrame()\n"
                        "    super.awakeFromNib()\n"
                        "    self.marcoEnsureWindowChromeVisible()\n"
                        "    self.marcoInstallWindowObservers()",
                        1,
                    )
            if "private final class HeadlessMediaWebSniffer" not in swift_text:
                swift_text = swift_text.rstrip() + "\n" + APPLE_WEB_SNIFFER_SWIFT
            if "extension MainFlutterWindow {" not in swift_text:
                swift_text = swift_text.rstrip() + "\n" + MACOS_WINDOW_EXTENSION_SWIFT
            window_swift.write_text(swift_text, encoding="utf-8")
    macos_podfile = ROOT / "macos" / "Podfile"
    if macos_podfile.exists():
        text = macos_podfile.read_text(encoding="utf-8")
        text = re.sub(
            r"#?\s*platform\s+:osx\s*,\s*'[^']+'",
            "platform :osx, '11.0'",
            text,
        )
        mpv_upgrade_marker = "# MarcoMovie: upgrade media_kit macOS libmpv to v0.7.3 (enables FFmpeg pgssub Blu-ray PGS decoder)"
        if mpv_upgrade_marker not in text and "flutter_install_all_macos_pods" in text:
            mpv_upgrade_ruby = (
                f"  {mpv_upgrade_marker}\n"
                "  begin\n"
                "    require 'fileutils'\n"
                "    mk_macos_dir = File.expand_path('Flutter/ephemeral/.symlinks/plugins/media_kit_libs_macos_video/macos', __dir__)\n"
                "    mk_makefile = File.join(mk_macos_dir, 'Makefile')\n"
                "    if File.exist?(mk_makefile)\n"
                "      mk_src = File.read(mk_makefile)\n"
                "      target_ver = 'v0.7.3'\n"
                "      target_sha = '2e58ac66b0ea875239bf4db29b3ef2100a719df1d61fa1e780c38d651d4c9f27'\n"
                "      unless mk_src.include?(\"MPV_XCFRAMEWORKS_VERSION=#{target_ver}\")\n"
                "        mk_src = mk_src.sub(/^MPV_XCFRAMEWORKS_VERSION=.*$/, \"MPV_XCFRAMEWORKS_VERSION=#{target_ver}\")\n"
                "        mk_src = mk_src.sub(/^MPV_XCFRAMEWORKS_SHA256SUM=.*$/, \"MPV_XCFRAMEWORKS_SHA256SUM=#{target_sha}\")\n"
                "        File.write(mk_makefile, mk_src)\n"
                "        Dir.glob(File.join(mk_macos_dir, 'Frameworks', '*.xcframework')).each { |p| FileUtils.rm_rf(p) }\n"
                "        FileUtils.rm_rf(File.join(mk_macos_dir, 'Frameworks', '.symlinks'))\n"
                "        Pod::UI.puts(\"MarcoMovie: upgraded media_kit macOS libmpv to #{target_ver} (pgssub enabled)\")\n"
                "      end\n"
                "    end\n"
                "  rescue => e\n"
                "    Pod::UI.warn(\"MarcoMovie: skipped libmpv v0.7.3 upgrade: #{e}\")\n"
                "  end\n\n"
            )
            text = re.sub(
                r"(^\s*flutter_install_all_macos_pods\b)",
                lambda m: mpv_upgrade_ruby + m.group(1),
                text,
                count=1,
                flags=re.MULTILINE,
            )
        vsync_patch_marker = "# MarcoMovie: enable CVDisplayLink vsync-paced vo=libmpv rendering for media_kit_video"
        if vsync_patch_marker not in text and "flutter_install_all_macos_pods" in text:
            vsync_patch_ruby = (
                f"  {vsync_patch_marker}\n"
                "  begin\n"
                "    prep = File.expand_path('../prepare_platform.py', __dir__)\n"
                "    if File.exist?(prep)\n"
                "      system('python3', prep, '--patch-media-kit-vsync')\n"
                "    end\n"
                "  rescue => e\n"
                "    Pod::UI.warn(\"MarcoMovie: skipped media_kit_video vsync patch: #{e}\")\n"
                "  end\n\n"
            )
            text = re.sub(
                r"(^\s*flutter_install_all_macos_pods\b)",
                lambda m: vsync_patch_ruby + m.group(1),
                text,
                count=1,
                flags=re.MULTILINE,
            )
        macos_podfile.write_text(text, encoding="utf-8")
    macos_pbx = ROOT / "macos" / "Runner.xcodeproj" / "project.pbxproj"
    if macos_pbx.exists():
        text = macos_pbx.read_text(encoding="utf-8")
        text = re.sub(
            r"MACOSX_DEPLOYMENT_TARGET\s*=\s*10\.\d+;",
            "MACOSX_DEPLOYMENT_TARGET = 11.0;",
            text,
        )
        text = text.replace("marco_movie.app", "MarcoMovie.app")
        text = text.replace(
            "$(BUNDLE_EXECUTABLE_FOLDER_PATH)/marco_movie",
            "$(BUNDLE_EXECUTABLE_FOLDER_PATH)/MarcoMovie",
        )
        macos_pbx.write_text(text, encoding="utf-8")
    macos_scheme = (
        ROOT / "macos" / "Runner.xcodeproj" / "xcshareddata" / "xcschemes" / "Runner.xcscheme"
    )
    if macos_scheme.exists():
        scheme_text = macos_scheme.read_text(encoding="utf-8")
        scheme_text = scheme_text.replace('BuildableName = "marco_movie.app"', 'BuildableName = "MarcoMovie.app"')
        macos_scheme.write_text(scheme_text, encoding="utf-8")
    _upgrade_macos_media_kit_mpv_v073()
    _upgrade_macos_media_kit_video_vsync()
    # iOS Info.plist, deployment target, and opaque AppIcon set
    ios_runner = ROOT / "ios" / "Runner"
    if ios_runner.exists():
        _replace_xcassets_icons(
            ios_runner / "Assets.xcassets" / "AppIcon.appiconset",
            IOS_ICON if IOS_ICON.exists() else (OPAQUE_ICON if OPAQUE_ICON.exists() else LOGO_MARK),
        )
        ios_plist = ios_runner / "Info.plist"
        if ios_plist.exists():
            info = plistlib.loads(ios_plist.read_bytes())
            info.update({
                'CFBundleDisplayName': 'Marco Movie',
                'CFBundleAllowMixedLocalizations': True,
                'UIStatusBarStyle': 'UIStatusBarStyleDefault',
                'UIViewControllerBasedStatusBarAppearance': True,
                # Unlock iPhone Duo dynamic fold/unfold resizing, Split View multitasking,
                # and free window sizing on iPadOS / iOS 27.1+.
                'UIRequiresFullScreen': False,
                'NSLocalNetworkUsageDescription': '用于发现局域网投屏电视（DLNA/AirPlay）及连接局域网 Emby 服务器与片源。',
                'NSBonjourServices': [
                    '_marcomovie-cast._tcp',
                    '_airplay._tcp',
                    '_raop._tcp',
                    '_lelink._tcp',
                    '_lebo._tcp',
                    '_googlecast._tcp',
                    '_dlna._tcp',
                    '_upnp._tcp',
                    '_http._tcp',
                ],
                'UIFileSharingEnabled': True,
                'LSSupportsOpeningDocumentsInPlace': True,
                'FlutterDeepLinkingEnabled': False,
                'LSApplicationQueriesSchemes': [
                    'apple-magnifier',
                    'qklink',
                    'qkcloudlink',
                    'quark',
                    'uclink',
                    'ucliteioslink',
                    'ucbrowser',
                    'bdnetdisk',
                    'baiduyun',
                    'baiduyunipad',
                    'baiduboxapp',
                    'smartdrive',
                    'alipan',
                    'aliyundrive',
                    'tbopen',
                    'taobao',
                ],
            })
            url_types = list(info.get('CFBundleURLTypes') or [])
            if not any('marcomovie' in (entry.get('CFBundleURLSchemes') or []) for entry in url_types if isinstance(entry, dict)):
                url_types.append({
                    'CFBundleTypeRole': 'Editor',
                    'CFBundleURLName': 'com.pilipala.marcoMovie',
                    'CFBundleURLSchemes': ['marcomovie'],
                })
            info['CFBundleURLTypes'] = url_types
            bg_modes = list(info.get('UIBackgroundModes') or [])
            if 'audio' not in bg_modes:
                bg_modes.append('audio')
            info['UIBackgroundModes'] = bg_modes
            info.setdefault('UILaunchStoryboardName', 'LaunchScreen')
            info.setdefault('UISupportedInterfaceOrientations', [
                'UIInterfaceOrientationPortrait',
                'UIInterfaceOrientationLandscapeLeft',
                'UIInterfaceOrientationLandscapeRight',
            ])
            info.setdefault('UISupportedInterfaceOrientations~ipad', [
                'UIInterfaceOrientationPortrait',
                'UIInterfaceOrientationPortraitUpsideDown',
                'UIInterfaceOrientationLandscapeLeft',
                'UIInterfaceOrientationLandscapeRight',
            ])
            # iOS 27.1 SDK / iPhone Duo mandates UIScene lifecycle; preserve Flutter 3.47+
            # generated manifests verbatim and provide a valid fallback if absent.
            scene_delegate_class = (
                '$(PRODUCT_MODULE_NAME).SceneDelegate'
                if (ios_runner / 'SceneDelegate.swift').exists()
                else 'FlutterSceneDelegate'
            )
            info.setdefault('UIApplicationSceneManifest', {
                'UIApplicationSupportsMultipleScenes': False,
                'UISceneConfigurations': {
                    'UIWindowSceneSessionRoleApplication': [
                        {
                            'UISceneClassName': 'UIWindowScene',
                            'UISceneConfigurationName': 'flutter',
                            'UISceneDelegateClassName': scene_delegate_class,
                            'UISceneStoryboardFile': 'Main',
                        },
                    ],
                },
            })
            info.setdefault('NSAppTransportSecurity', {})['NSAllowsArbitraryLoads'] = True
            ios_plist.write_bytes(plistlib.dumps(info, sort_keys=False))
        ios_storyboard = ios_runner / "Base.lproj" / "Main.storyboard"
        if ios_storyboard.exists():
            sb_text = ios_storyboard.read_text(encoding="utf-8")
            if 'customClass="FlutterViewController"' in sb_text:
                sb_text = sb_text.replace(
                    'customClass="FlutterViewController"',
                    'customClass="MarcoFlutterViewController" customModule="Runner" customModuleProvider="target"',
                )
                ios_storyboard.write_text(sb_text, encoding="utf-8")
        ios_app_delegate = ios_runner / "AppDelegate.swift"
        if ios_app_delegate.exists():
            ad_text = ios_app_delegate.read_text(encoding="utf-8")
            ad_changed = False
            if "import WebKit" not in ad_text and "import UIKit" in ad_text:
                ad_text = ad_text.replace("import UIKit", "import UIKit\nimport WebKit", 1)
                ad_changed = True
            if "import AVKit" not in ad_text and "import UIKit" in ad_text:
                ad_text = ad_text.replace("import UIKit", "import UIKit\nimport AVKit", 1)
                ad_changed = True
            if "import AVFoundation" not in ad_text and "import UIKit" in ad_text:
                ad_text = ad_text.replace("import UIKit", "import UIKit\nimport AVFoundation", 1)
                ad_changed = True
            if "MarcoNativeChannelRegistrar.register(" not in ad_text:
                if "GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)" in ad_text:
                    ad_text = ad_text.replace(
                        "GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)",
                        "GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)\n"
                        "    MarcoNativeChannelRegistrar.register(\n"
                        "      messenger: engineBridge.applicationRegistrar.messenger(),\n"
                        "      pluginRegistry: engineBridge.pluginRegistry\n"
                        "    )",
                        1,
                    )
                    ad_changed = True
                elif "GeneratedPluginRegistrant.register(with: self)" in ad_text:
                    ad_text = ad_text.replace(
                        "GeneratedPluginRegistrant.register(with: self)",
                        "GeneratedPluginRegistrant.register(with: self)\n"
                        "    if let messenger = (window?.rootViewController as? FlutterViewController)?.binaryMessenger\n"
                        "      ?? self.registrar(forPlugin: \"MarcoChannelBridge\")?.messenger() {\n"
                        "      MarcoNativeChannelRegistrar.register(messenger: messenger, pluginRegistry: self)\n"
                        "    }",
                        1,
                    )
                    ad_changed = True
            if "private enum MarcoNativeChannelRegistrar" not in ad_text:
                ad_text = ad_text.rstrip() + "\n" + IOS_NATIVE_CHANNEL_REGISTRAR_SWIFT
                ad_changed = True
            if "final class MarcoFlutterViewController" not in ad_text:
                ad_text = (
                    ad_text.rstrip()
                    + "\n\n@objc(MarcoFlutterViewController)\n"
                    "final class MarcoFlutterViewController: FlutterViewController {\n"
                    "  var marcoImmersiveMode: Bool = false {\n"
                    "    didSet {\n"
                    "      guard oldValue != marcoImmersiveMode else { return }\n"
                    "      setNeedsStatusBarAppearanceUpdate()\n"
                    "      if #available(iOS 11.0, *) {\n"
                    "        setNeedsUpdateOfHomeIndicatorAutoHidden()\n"
                    "        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()\n"
                    "      }\n"
                    "    }\n"
                    "  }\n\n"
                    "  var marcoPreferredInterfaceStyle: UIUserInterfaceStyle = .unspecified {\n"
                    "    didSet {\n"
                    "      setNeedsStatusBarAppearanceUpdate()\n"
                    "    }\n"
                    "  }\n\n"
                    "  private var orientationObserver: NSObjectProtocol?\n"
                    "  private weak var orientationChannel: FlutterMethodChannel?\n"
                    "  private var marcoOrientationMask: UIInterfaceOrientationMask?\n\n"
                    "  deinit {\n"
                    "    if let obs = orientationObserver {\n"
                    "      NotificationCenter.default.removeObserver(obs)\n"
                    "      UIDevice.current.endGeneratingDeviceOrientationNotifications()\n"
                    "    }\n"
                    "  }\n\n"
                    "  override var supportedInterfaceOrientations: UIInterfaceOrientationMask {\n"
                    "    return marcoOrientationMask ?? super.supportedInterfaceOrientations\n"
                    "  }\n\n"
                    "  override func viewWillTransition(\n"
                    "    to size: CGSize,\n"
                    "    with coordinator: UIViewControllerTransitionCoordinator\n"
                    "  ) {\n"
                    "    super.viewWillTransition(to: size, with: coordinator)\n"
                    "    MarcoLiquidGlassSupport.notifyWindowGeometryChanged(size: size)\n"
                    "    coordinator.animate(alongsideTransition: { [weak self] _ in\n"
                    "      self?.setNeedsStatusBarAppearanceUpdate()\n"
                    "    }, completion: nil)\n"
                    "  }\n\n"
                    "  override func viewSafeAreaInsetsDidChange() {\n"
                    "    super.viewSafeAreaInsetsDidChange()\n"
                    "    MarcoLiquidGlassSupport.notifyWindowGeometryChanged(size: view.bounds.size)\n"
                    "  }\n\n"
                    "  func setPhysicalOrientationMonitoring(_ enabled: Bool, channel: FlutterMethodChannel) {\n"
                    "    if let obs = orientationObserver {\n"
                    "      NotificationCenter.default.removeObserver(obs)\n"
                    "      orientationObserver = nil\n"
                    "    }\n"
                    "    orientationChannel = enabled ? channel : nil\n"
                    "    guard enabled else {\n"
                    "      UIDevice.current.endGeneratingDeviceOrientationNotifications()\n"
                    "      return\n"
                    "    }\n"
                    "    UIDevice.current.beginGeneratingDeviceOrientationNotifications()\n"
                    "    orientationObserver = NotificationCenter.default.addObserver(\n"
                    "      forName: UIDevice.orientationDidChangeNotification,\n"
                    "      object: nil,\n"
                    "      queue: .main\n"
                    "    ) { [weak self] _ in\n"
                    "      guard let self = self else { return }\n"
                    "      let label: String?\n"
                    "      switch UIDevice.current.orientation {\n"
                    "      case .portrait:\n"
                    "        label = \"portrait\"\n"
                    "      case .landscapeLeft:\n"
                    "        label = \"landscapeLeft\"\n"
                    "      case .landscapeRight:\n"
                    "        label = \"landscapeRight\"\n"
                    "      default:\n"
                    "        label = nil\n"
                    "      }\n"
                    "      if let label = label {\n"
                    "        self.orientationChannel?.invokeMethod(\"physicalOrientationChanged\", arguments: label)\n"
                    "      }\n"
                    "    }\n"
                    "  }\n\n"
                    "  func applyRequestedOrientation(_ mode: String) {\n"
                    "    let mask: UIInterfaceOrientationMask\n"
                    "    let fallbackRaw: Int?\n"
                    "    switch mode {\n"
                    "    case \"landscape\":\n"
                    "      mask = .landscape\n"
                    "      marcoOrientationMask = .landscape\n"
                    "      fallbackRaw = UIInterfaceOrientation.landscapeRight.rawValue\n"
                    "    case \"portrait\":\n"
                    "      mask = .portrait\n"
                    "      marcoOrientationMask = .portrait\n"
                    "      fallbackRaw = UIInterfaceOrientation.portrait.rawValue\n"
                    "    default:\n"
                    "      mask = .allButUpsideDown\n"
                    "      marcoOrientationMask = nil\n"
                    "      fallbackRaw = nil\n"
                    "    }\n"
                    "    if #available(iOS 16.0, *) {\n"
                    "      setNeedsUpdateOfSupportedInterfaceOrientations()\n"
                    "      if let scene = view.window?.windowScene {\n"
                    "        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }\n"
                    "      }\n"
                    "    } else if let raw = fallbackRaw {\n"
                    "      UIDevice.current.setValue(raw, forKey: \"orientation\")\n"
                    "      UIViewController.attemptRotationToDeviceOrientation()\n"
                    "    }\n"
                    "  }\n\n"
                    "  override var preferredStatusBarStyle: UIStatusBarStyle {\n"
                    "    if marcoImmersiveMode {\n"
                    "      return .lightContent\n"
                    "    }\n"
                    "    switch marcoPreferredInterfaceStyle {\n"
                    "    case .light:\n"
                    "      return .darkContent\n"
                    "    case .dark:\n"
                    "      return .lightContent\n"
                    "    default:\n"
                    "      return traitCollection.userInterfaceStyle == .light ? .darkContent : .lightContent\n"
                    "    }\n"
                    "  }\n\n"
                    "  override var prefersStatusBarHidden: Bool {\n"
                    "    return marcoImmersiveMode || super.prefersStatusBarHidden\n"
                    "  }\n\n"
                    "  override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {\n"
                    "    return .fade\n"
                    "  }\n\n"
                    "  override var prefersHomeIndicatorAutoHidden: Bool {\n"
                    "    return marcoImmersiveMode\n"
                    "  }\n\n"
                    "  override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {\n"
                    "    return marcoImmersiveMode ? [.top, .bottom] : []\n"
                    "  }\n"
                    "}\n"
                )
                ad_changed = True
            if "final class NetdiskWebAuthController" not in ad_text:
                ad_text = ad_text.rstrip() + "\n" + IOS_NETDISK_AUTH_CONTROLLER_SWIFT
                ad_changed = True
            if "private enum MarcoWebSnifferAndJsHostRegistrar" not in ad_text and IOS_WEB_SNIFFER_JS_HOST_SWIFT_PATH.is_file():
                # Strip any legacy APPLE_WEB_SNIFFER_SWIFT block before injecting upgraded sniffer & JS host.
                legacy_sniffer_re = re.compile(
                    r"\n*private final class WeakSnifferScriptHandler:.*?private final class HeadlessMediaWebSniffer:.*?\n\}\s*",
                    re.DOTALL,
                )
                if legacy_sniffer_re.search(ad_text):
                    ad_text = legacy_sniffer_re.sub("\n", ad_text)
                ad_text = ad_text.rstrip() + "\n\n" + IOS_WEB_SNIFFER_JS_HOST_SWIFT_PATH.read_text(encoding="utf-8")
                ad_changed = True
            if "enum MarcoAvPlayerEngine" not in ad_text and IOS_AVPLAYER_ENGINE_SWIFT_PATH.is_file():
                ad_text = ad_text.rstrip() + "\n\n" + IOS_AVPLAYER_ENGINE_SWIFT_PATH.read_text(encoding="utf-8")
                ad_changed = True
            if "private enum MarcoLiquidGlassSupport" not in ad_text and IOS_LIQUID_GLASS_SWIFT_PATH.is_file():
                ad_text = ad_text.rstrip() + "\n\n" + IOS_LIQUID_GLASS_SWIFT_PATH.read_text(encoding="utf-8")
                ad_changed = True
            if ad_changed:
                ios_app_delegate.write_text(ad_text, encoding="utf-8")
    ios_app_fw_plist = ROOT / "ios" / "Flutter" / "AppFrameworkInfo.plist"
    if ios_app_fw_plist.exists():
        text = ios_app_fw_plist.read_text(encoding="utf-8")
        text = re.sub(
            r"(<key>MinimumOSVersion</key>\s*<string>)[^<]+(</string>)",
            r"\g<1>15.0\g<2>",
            text,
        )
        ios_app_fw_plist.write_text(text, encoding="utf-8")
    for xcconfig_name in ("Release.xcconfig", "Debug.xcconfig", "Profile.xcconfig"):
        xcconfig = ROOT / "ios" / "Flutter" / xcconfig_name
        if xcconfig.exists():
            text = xcconfig.read_text(encoding="utf-8")
            text = re.sub(
                r"(?m)^IPHONEOS_DEPLOYMENT_TARGET\s*=.*$",
                "IPHONEOS_DEPLOYMENT_TARGET = 15.0",
                text,
            )
            text = re.sub(
                r"(?m)^OTHER_LDFLAGS\s*=\s*\$\(inherited\)\s+-Wl,-no_fixup_chains\s*$\n?",
                "",
                text,
            )
            if "IPHONEOS_DEPLOYMENT_TARGET = 15.0" not in text:
                text = text.rstrip() + "\nIPHONEOS_DEPLOYMENT_TARGET = 15.0\n"
            xcconfig.write_text(text, encoding="utf-8")
    ios_pbx = ROOT / "ios" / "Runner.xcodeproj" / "project.pbxproj"
    if ios_pbx.exists():
        text = ios_pbx.read_text(encoding="utf-8")
        text = re.sub(
            r"IPHONEOS_DEPLOYMENT_TARGET\s*=\s*[0-9.]+;",
            "IPHONEOS_DEPLOYMENT_TARGET = 15.0;",
            text,
        )
        ios_pbx.write_text(text, encoding="utf-8")
    ios_podfile = ROOT / "ios" / "Podfile"
    if ios_podfile.exists():
        text = ios_podfile.read_text(encoding="utf-8")
        text = re.sub(
            r"#?\s*platform\s+:ios\s*,\s*'[^']+'",
            "platform :ios, '15.0'",
            text,
        )
        if "Gem::Version.new('15.0')" not in text and "flutter_additional_ios_build_settings(target)" in text:
            text = text.replace(
                "flutter_additional_ios_build_settings(target)",
                "flutter_additional_ios_build_settings(target)\n"
                "    target.build_configurations.each do |config|\n"
                "      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0' if Gem::Version.new(config.build_settings.fetch('IPHONEOS_DEPLOYMENT_TARGET', '0')) < Gem::Version.new('15.0')\n"
                "    end",
            )
        ios_podfile.write_text(text, encoding="utf-8")
    # Windows icon, working directory, immediate window show, and title
    win_runner = ROOT / "windows" / "runner"
    win_native_dir = ROOT / "windows_native"
    if win_runner.exists() and win_native_dir.exists():
        for fname in (
            "marco_webview2_plugin.h",
            "marco_webview2_plugin.cpp",
            "CMakeFragment.cmake",
        ):
            src_file = win_native_dir / fname
            if src_file.is_file():
                shutil.copy2(src_file, win_runner / fname)
    win_ico = win_runner / "resources" / "app_icon.ico"
    if win_ico.parent.exists():
        _write_windows_ico(
            win_ico,
            LOGO_MARK,
        )
    win_main = win_runner / "main.cpp"
    if win_main.exists():
        text = win_main.read_text(encoding="utf-8")
        text = text.replace('L"marco_movie"', 'L"Marco Movie"')
        if "SetCurrentDirectoryW" not in text and "wWinMain(" in text:
            init_hook = (
                "  wchar_t exe_path[MAX_PATH];\n"
                "  if (::GetModuleFileNameW(nullptr, exe_path, MAX_PATH) > 0) {\n"
                "    wchar_t* last_slash = wcsrchr(exe_path, L'\\\\');\n"
                "    if (last_slash) {\n"
                "      *last_slash = L'\\0';\n"
                "      ::SetCurrentDirectoryW(exe_path);\n"
                "    }\n"
                "  }\n"
            )
            text = text.replace(
                "  // Attach to console when present",
                init_hook + "  // Attach to console when present",
                1,
            )
        win_main.write_text(text, encoding="utf-8")
    win_fw_h = win_runner / "flutter_window.h"
    if win_fw_h.exists():
        h_text = win_fw_h.read_text(encoding="utf-8")
        h_changed = False
        if "tray_channel_" not in h_text:
            if "<shellapi.h>" not in h_text:
                h_text = h_text.replace(
                    "#include <memory>",
                    "#include <flutter/method_channel.h>\n"
                    "#include <flutter/standard_method_codec.h>\n"
                    "#include <shellapi.h>\n\n"
                    "#include <memory>\n"
                    "#include <string>",
                    1,
                )
            h_text = h_text.replace(
                "  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;",
                "  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;\n"
                "  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> tray_channel_;\n"
                "  NOTIFYICONDATAW tray_data_{};\n"
                "  bool tray_icon_added_ = false;\n"
                "  UINT taskbar_created_msg_ = 0;\n"
                "  static constexpr UINT kTrayCallbackMsg = WM_APP + 101;\n"
                "  static constexpr UINT kTrayMenuRestoreId = 1001;\n"
                "  static constexpr UINT kTrayMenuQuitId = 1002;\n\n"
                "  bool AddTrayIcon(const std::wstring& tooltip);\n"
                "  void RemoveTrayIcon();\n"
                "  void RestoreFromTray();\n"
                "  void ShowTrayContextMenu(HWND hwnd);",
                1,
            )
            h_changed = True
        if h_changed:
            win_fw_h.write_text(h_text, encoding="utf-8")
    if win_fw_h.exists():
        h_text = win_fw_h.read_text(encoding="utf-8")
        h_changed = False
        if '#include "marco_webview2_plugin.h"' not in h_text and '#include "win32_window.h"' in h_text:
            h_text = h_text.replace(
                '#include "win32_window.h"',
                '#include "win32_window.h"\n#include "marco_webview2_plugin.h"',
                1,
            )
            h_changed = True
        if "webview2_plugin_" not in h_text and "flutter_controller_;" in h_text:
            h_text = h_text.replace(
                "  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;",
                "  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;\n"
                "  std::unique_ptr<marco::MarcoWebview2Plugin> webview2_plugin_;",
                1,
            )
            h_changed = True
        if h_changed:
            win_fw_h.write_text(h_text, encoding="utf-8")
    win_fw = win_runner / "flutter_window.cpp"
    if win_fw.exists():
        text = win_fw.read_text(encoding="utf-8")
        changed = False
        if '"resource.h"' not in text:
            text = text.replace(
                '#include "flutter_window.h"',
                '#include "flutter_window.h"\n#include "resource.h"',
                1,
            )
            changed = True
        if "marco_movie/wakelock" not in text and "RegisterPlugins(flutter_controller_->engine());" in text:
            if "<flutter/method_channel.h>" not in text:
                text = "#include <flutter/method_channel.h>\n#include <flutter/standard_method_codec.h>\n" + text
            text = text.replace(
                "RegisterPlugins(flutter_controller_->engine());",
                "RegisterPlugins(flutter_controller_->engine());\n"
                "  flutter::MethodChannel<flutter::EncodableValue> wakelock_channel(\n"
                "      flutter_controller_->engine()->messenger(), \"marco_movie/wakelock\",\n"
                "      &flutter::StandardMethodCodec::GetInstance());\n"
                "  wakelock_channel.SetMethodCallHandler(\n"
                "      [](const flutter::MethodCall<flutter::EncodableValue>& call,\n"
                "         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {\n"
                "        if (call.method_name() == \"setEnabled\") {\n"
                "          const auto* enabled = std::get_if<bool>(call.arguments());\n"
                "          ::SetThreadExecutionState((enabled && *enabled)\n"
                "              ? (ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED)\n"
                "              : ES_CONTINUOUS);\n"
                "          result->Success();\n"
                "        } else {\n"
                "          result->NotImplemented();\n"
                "        }\n"
                "      });",
                1,
            )
            changed = True
        if "marco_movie/windows_tray" not in text and "RegisterPlugins(flutter_controller_->engine());" in text:
            tray_setup = (
                "  taskbar_created_msg_ = ::RegisterWindowMessageW(L\"TaskbarCreated\");\n"
                "  tray_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(\n"
                "      flutter_controller_->engine()->messenger(), \"marco_movie/windows_tray\",\n"
                "      &flutter::StandardMethodCodec::GetInstance());\n"
                "  tray_channel_->SetMethodCallHandler(\n"
                "      [this](const flutter::MethodCall<flutter::EncodableValue>& call,\n"
                "             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {\n"
                "        if (call.method_name() == \"hideToTray\") {\n"
                "          std::wstring tip = L\"Marco Movie\";\n"
                "          if (const auto* map = std::get_if<flutter::EncodableMap>(call.arguments())) {\n"
                "            auto it = map->find(flutter::EncodableValue(\"tooltip\"));\n"
                "            if (it != map->end()) {\n"
                "              if (const auto* utf8 = std::get_if<std::string>(&it->second); utf8 && !utf8->empty()) {\n"
                "                int needed = ::MultiByteToWideChar(CP_UTF8, 0, utf8->c_str(), -1, nullptr, 0);\n"
                "                if (needed > 1) {\n"
                "                  std::wstring converted(static_cast<size_t>(needed - 1), L'\\0');\n"
                "                  ::MultiByteToWideChar(CP_UTF8, 0, utf8->c_str(), -1, converted.data(), needed);\n"
                "                  tip = converted;\n"
                "                }\n"
                "              }\n"
                "            }\n"
                "          }\n"
                "          bool ok = AddTrayIcon(tip);\n"
                "          if (ok && GetHandle()) {\n"
                "            ::ShowWindow(GetHandle(), SW_HIDE);\n"
                "          }\n"
                "          result->Success(flutter::EncodableValue(ok));\n"
                "        } else if (call.method_name() == \"showFromTray\") {\n"
                "          RestoreFromTray();\n"
                "          result->Success(flutter::EncodableValue(true));\n"
                "        } else if (call.method_name() == \"removeTray\") {\n"
                "          RemoveTrayIcon();\n"
                "          result->Success(flutter::EncodableValue(true));\n"
                "        } else {\n"
                "          result->NotImplemented();\n"
                "        }\n"
                "      });\n"
            )
            text = text.replace(
                "  SetChildContent(flutter_controller_->view()->GetNativeWindow());",
                tray_setup + "  SetChildContent(flutter_controller_->view()->GetNativeWindow());",
                1,
            )
            changed = True
        if "tray_channel_.reset();" not in text and "void FlutterWindow::OnDestroy()" in text:
            text = text.replace(
                "void FlutterWindow::OnDestroy() {",
                "void FlutterWindow::OnDestroy() {\n"
                "  RemoveTrayIcon();\n"
                "  tray_channel_.reset();",
                1,
            )
            changed = True
        if "case kTrayCallbackMsg:" not in text and "switch (message) {" in text:
            text = text.replace(
                "  switch (message) {",
                "  if (taskbar_created_msg_ != 0 && message == taskbar_created_msg_ && tray_icon_added_) {\n"
                "    ::Shell_NotifyIconW(NIM_ADD, &tray_data_);\n"
                "    return 0;\n"
                "  }\n\n"
                "  switch (message) {\n"
                "    case kTrayCallbackMsg: {\n"
                "      const UINT evt = LOWORD(lparam);\n"
                "      if (evt == WM_LBUTTONUP || evt == WM_LBUTTONDBLCLK) {\n"
                "        RestoreFromTray();\n"
                "        return 0;\n"
                "      }\n"
                "      if (evt == WM_RBUTTONUP || evt == WM_CONTEXTMENU) {\n"
                "        ShowTrayContextMenu(hwnd);\n"
                "        return 0;\n"
                "      }\n"
                "      return 0;\n"
                "    }",
                1,
            )
            changed = True
        if "bool FlutterWindow::AddTrayIcon(" not in text:
            text = (
                text.rstrip()
                + "\n\n"
                + "bool FlutterWindow::AddTrayIcon(const std::wstring& tooltip) {\n"
                + "  HWND hwnd = GetHandle();\n"
                + "  if (!hwnd) {\n"
                + "    return false;\n"
                + "  }\n"
                + "  if (tray_icon_added_) {\n"
                + "    wcsncpy_s(tray_data_.szTip,\n"
                + "              tooltip.empty() ? L\"Marco Movie\" : tooltip.c_str(), _TRUNCATE);\n"
                + "    ::Shell_NotifyIconW(NIM_MODIFY, &tray_data_);\n"
                + "    return true;\n"
                + "  }\n"
                + "  tray_data_ = {};\n"
                + "  tray_data_.cbSize = sizeof(NOTIFYICONDATAW);\n"
                + "  tray_data_.hWnd = hwnd;\n"
                + "  tray_data_.uID = 1;\n"
                + "  tray_data_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;\n"
                + "  tray_data_.uCallbackMessage = kTrayCallbackMsg;\n"
                + "  tray_data_.hIcon = ::LoadIconW(::GetModuleHandleW(nullptr),\n"
                + "                                 MAKEINTRESOURCEW(IDI_APP_ICON));\n"
                + "  if (!tray_data_.hIcon) {\n"
                + "    tray_data_.hIcon = ::LoadIconW(nullptr, IDI_APPLICATION);\n"
                + "  }\n"
                + "  wcsncpy_s(tray_data_.szTip,\n"
                + "            tooltip.empty() ? L\"Marco Movie\" : tooltip.c_str(), _TRUNCATE);\n"
                + "  tray_icon_added_ = (::Shell_NotifyIconW(NIM_ADD, &tray_data_) == TRUE);\n"
                + "  return tray_icon_added_;\n"
                + "}\n\n"
                + "void FlutterWindow::RemoveTrayIcon() {\n"
                + "  if (tray_icon_added_) {\n"
                + "    ::Shell_NotifyIconW(NIM_DELETE, &tray_data_);\n"
                + "    tray_icon_added_ = false;\n"
                + "  }\n"
                + "}\n\n"
                + "void FlutterWindow::RestoreFromTray() {\n"
                + "  RemoveTrayIcon();\n"
                + "  HWND hwnd = GetHandle();\n"
                + "  if (hwnd) {\n"
                + "    ::ShowWindow(hwnd, SW_SHOW);\n"
                + "    if (::IsIconic(hwnd)) {\n"
                + "      ::ShowWindow(hwnd, SW_RESTORE);\n"
                + "    }\n"
                + "    ::SetForegroundWindow(hwnd);\n"
                + "  }\n"
                + "  if (tray_channel_) {\n"
                + "    tray_channel_->InvokeMethod(\"restore\", nullptr);\n"
                + "  }\n"
                + "}\n\n"
                + "void FlutterWindow::ShowTrayContextMenu(HWND hwnd) {\n"
                + "  HMENU menu = ::CreatePopupMenu();\n"
                + "  if (!menu) {\n"
                + "    return;\n"
                + "  }\n"
                + "  ::AppendMenuW(menu, MF_STRING, kTrayMenuRestoreId,\n"
                + "                L\"\\u663e\\u793a Marco Movie\");\n"
                + "  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);\n"
                + "  ::AppendMenuW(menu, MF_STRING, kTrayMenuQuitId,\n"
                + "                L\"\\u9000\\u51fa Marco Movie\");\n"
                + "  ::SetMenuDefaultItem(menu, kTrayMenuRestoreId, FALSE);\n"
                + "  POINT pt{};\n"
                + "  ::GetCursorPos(&pt);\n"
                + "  ::SetForegroundWindow(hwnd);\n"
                + "  UINT cmd = static_cast<UINT>(::TrackPopupMenu(\n"
                + "      menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY,\n"
                + "      pt.x, pt.y, 0, hwnd, nullptr));\n"
                + "  ::PostMessageW(hwnd, WM_NULL, 0, 0);\n"
                + "  ::DestroyMenu(menu);\n"
                + "  if (cmd == kTrayMenuRestoreId) {\n"
                + "    RestoreFromTray();\n"
                + "  } else if (cmd == kTrayMenuQuitId) {\n"
                + "    RemoveTrayIcon();\n"
                + "    if (tray_channel_) {\n"
                + "      tray_channel_->InvokeMethod(\"quit\", nullptr);\n"
                + "    } else {\n"
                + "      ::PostMessageW(hwnd, WM_CLOSE, 0, 0);\n"
                + "    }\n"
                + "  }\n"
                + "}\n"
            )
            changed = True
        if "this->Show();" in text and "// Immediate Show on Windows" not in text:
            text = text.replace(
                "SetChildContent(flutter_controller_->view()->GetNativeWindow());",
                "SetChildContent(flutter_controller_->view()->GetNativeWindow());\n"
                "  // Immediate Show on Windows so the window always appears right away\n"
                "  this->Show();",
                1,
            )
            changed = True
        if "webview2_plugin_ = " not in text and "RegisterPlugins(flutter_controller_->engine());" in text:
            text = text.replace(
                "RegisterPlugins(flutter_controller_->engine());",
                "RegisterPlugins(flutter_controller_->engine());\n"
                "  webview2_plugin_ = std::make_unique<marco::MarcoWebview2Plugin>(\n"
                "      flutter_controller_->engine()->messenger(), GetHandle());",
                1,
            )
            changed = True
        if "webview2_plugin_->Shutdown()" not in text and "void FlutterWindow::OnDestroy()" in text:
            text = text.replace(
                "void FlutterWindow::OnDestroy() {",
                "void FlutterWindow::OnDestroy() {\n"
                "  if (webview2_plugin_) {\n"
                "    webview2_plugin_->Shutdown();\n"
                "    webview2_plugin_.reset();\n"
                "  }",
                1,
            )
            changed = True
        if changed:
            win_fw.write_text(text, encoding="utf-8")
    win_runner_cmake = win_runner / "CMakeLists.txt"
    if win_runner_cmake.exists():
        cmake_text = win_runner_cmake.read_text(encoding="utf-8")
        cmake_changed = False
        if '"shell32.lib"' not in cmake_text and '"dwmapi.lib"' in cmake_text:
            cmake_text = cmake_text.replace(
                'target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")',
                'target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib" "shell32.lib")',
                1,
            )
            cmake_changed = True
        if "CMakeFragment.cmake" not in cmake_text and (win_runner / "CMakeFragment.cmake").is_file():
            cmake_text = cmake_text.rstrip() + "\n\ninclude(CMakeFragment.cmake)\n"
            cmake_changed = True
        if cmake_changed:
            win_runner_cmake.write_text(cmake_text, encoding="utf-8")

if __name__ == "__main__":
    if "--patch-media-kit-vsync" in sys.argv[1:]:
        _upgrade_macos_media_kit_video_vsync()
    else:
        main()
