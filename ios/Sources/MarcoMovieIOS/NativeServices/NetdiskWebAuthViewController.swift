// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Marco Movie iOS — Pure UIKit/WebKit Netdisk OAuth/Cookie Authorization Modal (Quark / UC / Baidu / Ali / 115)

import UIKit
import WebKit

// MARK: - Supported Netdisk Providers & Auth Result

public enum NetdiskDriveKind: String, CaseIterable, Sendable {
    case quark = "quark"
    case uc = "uc"
    case baidu = "baidu"
    case ali = "ali"
    case drive115 = "drive115"

    /// Flexible initializer accepting common provider identifiers (`quark`, `uc`, `baidu`, `ali`, `115`, `drive115`).
    public init?(identifier: String) {
        switch identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "quark":
            self = .quark
        case "uc":
            self = .uc
        case "baidu":
            self = .baidu
        case "ali", "aliyun", "alipan":
            self = .ali
        case "drive115", "115", "115pan":
            self = .drive115
        default:
            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .quark: return "夸克网盘"
        case .uc: return "UC网盘"
        case .baidu: return "百度网盘"
        case .ali: return "阿里云盘"
        case .drive115: return "115网盘"
        }
    }

    public var authSheetTitle: String {
        "\(displayName)登录授权"
    }

    public var defaultAuthURLString: String {
        switch self {
        case .quark:
            return "https://pan.quark.cn/"
        case .uc:
            return "https://drive.uc.cn/"
        case .baidu:
            return "https://wappass.baidu.com/passport/?login&tpl=netdisk&u=https%3A%2F%2Fpan.baidu.com%2Fdisk%2Fhome"
        case .ali:
            return "https://www.alipan.com/sign/in"
        case .drive115:
            var comps = URLComponents()
            comps.scheme = "https"
            comps.host = "115.com"
            comps.path = "/"
            return comps.url?.absoluteString ?? ""
        }
    }

    public var prefersMobileUserAgent: Bool {
        self == .baidu || self == .ali
    }
}

public enum NetdiskAuthWebResult: Equatable, Sendable {
    /// Captured cookie string (`__pus=...; __puus=...`, `BDUSS=...; STOKEN=...`, `UID=...; CID=...; SEID=...`, `ali_token=...`).
    case credential(String)
    /// Captured Alibaba `bizExt` payload for secondary refresh-token decode.
    case bizExt(String)
    /// User tapped "App扫码" on Ali Drive to jump into app-based QR authorization.
    case openScanApp
}

// MARK: - Weak Script Handler & Thread-Safe Completion Box

private final class WeakAuthScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

private final class AuthCompletionBox {
    private let lock = NSLock()
    private var handler: ((NetdiskAuthWebResult?) -> Void)?

    init(_ handler: ((NetdiskAuthWebResult?) -> Void)?) {
        self.handler = handler
    }

    func set(_ handler: ((NetdiskAuthWebResult?) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func fireOnce(_ result: NetdiskAuthWebResult?) {
        let cb: ((NetdiskAuthWebResult?) -> Void)?
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

// MARK: - Netdisk Web Authorization Modal Controller

/// Pure UIKit/WebKit modal supporting full interactive cookie/token authorization for
/// Quark, UC, Baidu (including App jump + STOKEN follow-up), Ali (postMessage/Storage/XHR/fetch hook),
/// and 115 (UID + CID + SEID cookies on `*.115.com`).
public final class NetdiskWebAuthViewController: UIViewController,
    WKNavigationDelegate,
    WKUIDelegate,
    WKScriptMessageHandler,
    WKHTTPCookieStoreObserver,
    UIAdaptivePresentationControllerDelegate {

    private static let mobileSafariUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private static let desktopSafariUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

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

    public let drive: NetdiskDriveKind
    public let initialUrlString: String
    public let qrUrlString: String

    /// Invoked once on the main thread when authorization succeeds, triggers Ali app scan, or is dismissed.
    public var onComplete: ((NetdiskAuthWebResult?) -> Void)? {
        didSet {
            completionBox.set(onComplete)
        }
    }

    private let completionBox: AuthCompletionBox
    private var completed = false
    private var panAuthTriggered = false
    private var webView: WKWebView!
    private var dataStore: WKWebsiteDataStore?
    private let hintBanner = UIView()
    private let hintLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private var progressObservation: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []

    public init(
        drive: NetdiskDriveKind,
        urlString: String? = nil,
        qrUrlString: String = "",
        onComplete: ((NetdiskAuthWebResult?) -> Void)? = nil
    ) {
        self.drive = drive
        let trimmed = (urlString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.initialUrlString = trimmed.isEmpty ? drive.defaultAuthURLString : trimmed
        self.qrUrlString = qrUrlString
        self.onComplete = onComplete
        self.completionBox = AuthCompletionBox(onComplete)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        completionBox.fireOnce(nil)
    }

    /// Presents the netdisk authorization sheet adaptively (iPad centered `.formSheet` 540x620, iPhone `.large` sheet).
    public static func present(
        from root: UIViewController?,
        drive: NetdiskDriveKind,
        urlString: String? = nil,
        qrUrlString: String = "",
        onComplete: @escaping (NetdiskAuthWebResult?) -> Void
    ) {
        guard let root = root else {
            onComplete(nil)
            return
        }
        let vc = NetdiskWebAuthViewController(
            drive: drive,
            urlString: urlString,
            qrUrlString: qrUrlString,
            onComplete: onComplete
        )
        let nav = UINavigationController(rootViewController: vc)
        let options = MarcoModalOptions(
            detents: [.large],
            preferredFormSheetSize: CGSize(width: 540, height: 640),
            prefersGrabberVisible: false,
            preferredCornerRadius: MarcoRadii.sheet,
            wrapInNavigationController: false,
            presentationDelegate: vc
        )
        MarcoModalPresenter.present(nav, from: root, options: options)
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = MarcoThemeManager.shared.currentInterfaceStyle
        view.backgroundColor = MarcoColors.canvasBackground
        navigationItem.title = drive.authSheetTitle
        navigationItem.largeTitleDisplayMode = .never

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "关闭",
            style: .plain,
            target: self,
            action: #selector(closeTapped)
        )

        var rightItems: [UIBarButtonItem] = []
        let reloadIcon = MarcoSymbols.image("arrow.clockwise", pointSize: 15, weight: .medium)
        rightItems.append(UIBarButtonItem(
            image: reloadIcon,
            style: .plain,
            target: self,
            action: #selector(reloadTapped)
        ))
        if drive == .ali {
            rightItems.append(UIBarButtonItem(
                title: "App扫码",
                style: .plain,
                target: self,
                action: #selector(openScanAppTapped)
            ))
        }
        navigationItem.rightBarButtonItems = rightItems

        let config = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        self.dataStore = store
        config.websiteDataStore = store

        let contentController = WKUserContentController()
        contentController.add(WeakAuthScriptMessageHandler(self), name: "marcoAuth")
        if drive == .ali {
            contentController.addUserScript(
                WKUserScript(source: Self.aliHookScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        } else if drive == .baidu {
            contentController.addUserScript(
                WKUserScript(source: Self.baiduAppJumpScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }
        config.userContentController = contentController
        store.httpCookieStore.add(self)

        hintBanner.translatesAutoresizingMaskIntoConstraints = false
        hintBanner.backgroundColor = MarcoColors.elevatedSurface

        let hairline = UIView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.backgroundColor = MarcoColors.separator
        hintBanner.addSubview(hairline)

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = MarcoTypography.caption
        hintLabel.textColor = MarcoColors.secondaryText
        hintLabel.numberOfLines = 2
        hintLabel.textAlignment = .center
        hintLabel.text = initialHintText()
        hintBanner.addSubview(hintLabel)

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.trackTintColor = .clear
        progressView.progressTintColor = MarcoColors.accentTint
        progressView.isHidden = true

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.customUserAgent = drive.prefersMobileUserAgent ? Self.mobileSafariUA : Self.desktopSafariUA
        self.webView = wv

        progressObservation = wv.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let progress = Float(webView.estimatedProgress)
                self.progressView.isHidden = progress >= 1.0
                self.progressView.setProgress(progress, animated: progress > self.progressView.progress)
            }
        }

        view.addSubview(hintBanner)
        view.addSubview(wv)
        view.addSubview(progressView)

        let guide = view.safeAreaLayoutGuide
        let pixelHeight = 1.0 / max(UIScreen.main.scale, 1.0)
        NSLayoutConstraint.activate([
            hintBanner.topAnchor.constraint(equalTo: guide.topAnchor),
            hintBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hintBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            hintLabel.topAnchor.constraint(equalTo: hintBanner.topAnchor, constant: 8),
            hintLabel.bottomAnchor.constraint(equalTo: hintBanner.bottomAnchor, constant: -8),
            hintLabel.leadingAnchor.constraint(equalTo: hintBanner.leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(equalTo: hintBanner.trailingAnchor, constant: -16),

            hairline.leadingAnchor.constraint(equalTo: hintBanner.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: hintBanner.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: hintBanner.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: pixelHeight),

            progressView.topAnchor.constraint(equalTo: hintBanner.bottomAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),

            wv.topAnchor.constraint(equalTo: hintBanner.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let center = NotificationCenter.default
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willEnterForegroundNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handleAppForegrounded()
            }
            notificationObservers.append(token)
        }

        if let targetUrl = URL(string: resolvedInitialUrl()) {
            wv.load(URLRequest(url: targetUrl))
        }
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

    @objc private func closeTapped() {
        finish(with: nil, dismissModal: true)
    }

    @objc private func reloadTapped() {
        MarcoHaptics.selection()
        if webView.url != nil {
            webView.reload()
        } else if let targetUrl = URL(string: resolvedInitialUrl()) {
            webView.load(URLRequest(url: targetUrl))
        }
    }

    @objc private func openScanAppTapped() {
        MarcoHaptics.selection()
        finish(with: .openScanApp, dismissModal: true)
    }

    // MARK: - Provider Helpers

    private func initialHintText() -> String {
        switch drive {
        case .baidu:
            for scheme in ["bdnetdisk://", "baiduyunipad://", "baiduyun://"] {
                if let u = URL(string: scheme), UIApplication.shared.canOpenURL(u) {
                    return "正在唤起百度网盘 App，确认「授权登录」后返回即可自动完成登录"
                }
            }
            return "支持唤起百度 App 授权或直接在此页面登录，完成后自动同步"
        case .ali:
            return "支持本机免密 / 淘宝跳转 / 验证码登录，或点右上角用阿里云盘扫码"
        case .drive115:
            return "登录 115 网盘账号或扫码授权后，将自动捕获会话凭证并同步返回"
        case .quark, .uc:
            return "登录完成后将自动同步网盘状态并返回"
        }
    }

    private func resolvedInitialUrl() -> String {
        guard drive == .baidu else { return initialUrlString }
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
        if drive == .baidu {
            wv.evaluateJavaScript(
                "try { document.dispatchEvent(new Event('visibilitychange')); window.dispatchEvent(new Event('focus')); window.dispatchEvent(new Event('pageshow')); } catch (_) {}",
                completionHandler: nil
            )
        }
        inspectCookies()
    }

    // MARK: - WKWebView Delegates

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
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
            let patched = raw.replacingOccurrences(
                of: "browserScheme=&",
                with: "browserScheme=marcomovie%3A%2F%2Fauth&"
            )
            let finalStr = patched.hasSuffix("browserScheme=")
                ? (patched + "marcomovie%3A%2F%2Fauth")
                : patched
            if let rewritten = URL(string: finalStr) {
                targetUrl = rewritten
            }
        }
        UIApplication.shared.open(targetUrl, options: [:], completionHandler: nil)
        decisionHandler(.cancel)
    }

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
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

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        inspectCookies()
    }

    public func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        inspectCookies()
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "marcoAuth", !completed else { return }
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            return
        }
        if type == "credential", let cred = body["credential"] as? String, !cred.isEmpty {
            MarcoHaptics.success()
            finish(with: .credential(cred), dismissModal: true)
        } else if type == "bizExt", let biz = body["bizExt"] as? String, !biz.isEmpty {
            MarcoHaptics.success()
            finish(with: .bizExt(biz), dismissModal: true)
        }
    }

    // MARK: - Cookie Evaluation (All 5 Providers)

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
            switch self.drive {
            case .baidu:
                self.evaluateBaiduCookies(valid)
            case .quark:
                self.evaluateQuarkCookies(valid)
            case .uc:
                self.evaluateUcCookies(valid)
            case .drive115:
                self.evaluate115Cookies(valid)
            case .ali:
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
        MarcoHaptics.success()
        finish(with: .credential(parts.joined(separator: "; ")), dismissModal: true)
    }

    private func evaluateQuarkCookies(_ valid: [HTTPCookie]) {
        var map: [String: String] = [:]
        for c in valid {
            let dom = c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            if dom == "quark.cn" || dom.hasSuffix(".quark.cn") {
                map[c.name] = c.value
            }
        }
        guard let pus = map["__pus"], !pus.isEmpty,
              let puus = map["__puus"], !puus.isEmpty else {
            return
        }
        let header = map.keys.sorted().compactMap { key in
            map[key].map { "\(key)=\($0)" }
        }.joined(separator: "; ")
        MarcoHaptics.success()
        finish(with: .credential(header), dismissModal: true)
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
        let header = map.keys.sorted().compactMap { key in
            map[key].map { "\(key)=\($0)" }
        }.joined(separator: "; ")
        MarcoHaptics.success()
        finish(with: .credential(header), dismissModal: true)
    }

    private func evaluate115Cookies(_ valid: [HTTPCookie]) {
        var map: [String: String] = [:]
        for c in valid {
            let dom = c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            if dom == "115.com" || dom.hasSuffix(".115.com") {
                map[c.name] = c.value
            }
        }
        guard let uid = map["UID"], !uid.isEmpty,
              let cid = map["CID"], !cid.isEmpty,
              let seid = map["SEID"], !seid.isEmpty else {
            return
        }
        var parts: [String] = [
            "UID=\(uid)",
            "CID=\(cid)",
            "SEID=\(seid)",
        ]
        if let kid = map["KID"], !kid.isEmpty {
            parts.append("KID=\(kid)")
        }
        MarcoHaptics.success()
        finish(with: .credential(parts.joined(separator: "; ")), dismissModal: true)
    }

    // MARK: - Teardown

    private func cleanupObservers() {
        let center = NotificationCenter.default
        for token in notificationObservers {
            center.removeObserver(token)
        }
        notificationObservers.removeAll()
        progressObservation?.invalidate()
        progressObservation = nil
        dataStore?.httpCookieStore.remove(self)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "marcoAuth")
        webView?.stopLoading()
    }

    private func finish(with result: NetdiskAuthWebResult?, dismissModal: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.finish(with: result, dismissModal: dismissModal)
            }
            return
        }
        guard !completed else { return }
        completed = true
        cleanupObservers()
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
}
