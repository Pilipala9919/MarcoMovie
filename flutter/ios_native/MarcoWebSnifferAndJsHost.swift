// MARK: - iOS WKWebView Rule Sniffer, WKContentRuleList Ad Blocker & Offscreen Async JS Host
// Injected into Runner/AppDelegate.swift by prepare_platform.py (which already imports Flutter, UIKit, WebKit).

private enum MarcoWebSnifferAndJsHostRegistrar {
  static func register(messenger: FlutterBinaryMessenger) {
    let snifferChannel = FlutterMethodChannel(
      name: "marco_movie/web_sniffer",
      binaryMessenger: messenger
    )
    snifferChannel.setMethodCallHandler { call, result in
      if call.method == "sniffMedia", let args = call.arguments as? [String: Any] {
        let urlStr = (args["url"] as? String) ?? ""
        let rawHeaders = (args["headers"] as? [String: Any]) ?? [:]
        var headers: [String: String] = [:]
        for (k, v) in rawHeaders {
          headers[k] = "\(v)"
        }
        let timeoutMs = (args["timeoutMs"] as? Int) ?? 12000
        let rules = (args["rules"] as? [[String: Any]]) ?? []
        let ads = (args["ads"] as? [String]) ?? []
        let clickScript = (args["clickScript"] as? String) ?? ""
        HeadlessMediaWebSniffer.sniff(
          urlString: urlStr,
          headers: headers,
          timeoutMs: timeoutMs,
          rules: rules,
          ads: ads,
          clickScript: clickScript,
          completion: result
        )
      } else if call.method == "clearAdBlockCache" {
        HeadlessMediaWebSniffer.clearAdBlockCache {
          result(true)
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    let webviewJsChannel = FlutterMethodChannel(
      name: "marco_movie/webview_js",
      binaryMessenger: messenger
    )
    webviewJsChannel.setMethodCallHandler { call, result in
      if #available(iOS 14.0, *) {
        MarcoOffscreenWebJsHost.shared.handle(call: call, result: result)
      } else {
        result(FlutterError(
          code: "unsupported_os",
          message: "Offscreen WKWebView JS host requires iOS 14.0+",
          details: nil
        ))
      }
    }
  }
}

private final class WeakSnifferScriptHandler: NSObject, WKScriptMessageHandler {
  weak var target: HeadlessMediaWebSniffer?
  init(_ target: HeadlessMediaWebSniffer) { self.target = target }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    target?.userContentController(userContentController, didReceive: message)
  }
}

private final class HeadlessMediaWebSniffer: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
  private static var activeSniffers = Set<HeadlessMediaWebSniffer>()
  private static var compiledRuleCache: [String: WKContentRuleList] = [:]
  private static let desktopSafariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

  private static func buildHookScript(
    customRegexPatterns: [String],
    excludePatterns: [String],
    adHosts: [String]
  ) -> String {
    let regexJson = (try? String(
      data: JSONSerialization.data(withJSONObject: customRegexPatterns, options: []),
      encoding: .utf8
    )) ?? "[]"
    let excludeJson = (try? String(
      data: JSONSerialization.data(withJSONObject: excludePatterns, options: []),
      encoding: .utf8
    )) ?? "[]"
    let adHostsJson = (try? String(
      data: JSONSerialization.data(withJSONObject: adHosts, options: []),
      encoding: .utf8
    )) ?? "[]"

    return """
    (function() {
      var customRegexes = (\(regexJson)).map(function(p) {
        try { return new RegExp(p, 'i'); } catch (_) { return null; }
      }).filter(Boolean);
      var excludeRegexes = (\(excludeJson)).map(function(p) {
        try { return new RegExp(p, 'i'); } catch (_) { return null; }
      }).filter(Boolean);
      var adHosts = (\(adHostsJson)).map(function(h) { return String(h || '').toLowerCase(); }).filter(Boolean);

      function isBlocked(u) {
        if (!u) return true;
        var lower = u.toLowerCase();
        for (var i = 0; i < adHosts.length; i++) {
          var ad = adHosts[i];
          if (lower.indexOf(ad) >= 0) return true;
        }
        for (var j = 0; j < excludeRegexes.length; j++) {
          if (excludeRegexes[j].test(u)) return true;
        }
        return false;
      }

      function looksMedia(u) {
        if (!u || typeof u !== 'string') return false;
        var trimmed = u.trim();
        if (!/^https?:\\/\\//i.test(trimmed)) return false;
        if (isBlocked(trimmed)) return false;
        for (var i = 0; i < customRegexes.length; i++) {
          if (customRegexes[i].test(trimmed)) return true;
        }
        if (/\\.(?:js|mjs|css|png|jpe?g|gif|webp|svg|ico|woff2?|ttf|json|xml|vtt|srt|html?|php)(?:$|[?#])/i.test(trimmed)) return false;
        return /\\.(?:m3u8?|mp4|flv|mkv|mpd|webm|m4v|mov)(?:$|[?#])/i.test(trimmed) ||
               /[?&](?:type|format|mime)=[^&#]*(?:m3u8|mp4|flv|mpegurl|video)/i.test(trimmed);
      }

      function report(raw) {
        try {
          if (!raw || typeof raw !== 'string') return;
          var abs = new URL(raw.trim(), location.href).href;
          if (!looksMedia(abs)) return;
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
      window.__marcoScanDom = scanDom;
      setInterval(scanDom, 350);
      document.addEventListener('DOMContentLoaded', scanDom, true);
    })();
    """
  }

  private struct SniffRuleEntry {
    let hosts: [String]
    let regexPatterns: [String]
    let excludePatterns: [String]
    let regexes: [NSRegularExpression]
    let excludes: [NSRegularExpression]
    let clickScript: String
  }

  private let targetUrl: URL
  private let headers: [String: String]
  private let timeoutMs: Int
  private let parsedRules: [SniffRuleEntry]
  private let ads: [String]
  private let explicitClickScript: String
  private var effectiveUa: String
  private var completion: FlutterResult?
  private var completed = false
  private var webView: WKWebView?
  private var dataStore: WKWebsiteDataStore?
  private var activeCustomRegexes: [NSRegularExpression] = []
  private var activeExcludeRegexes: [NSRegularExpression] = []

  private init(
    targetUrl: URL,
    headers: [String: String],
    timeoutMs: Int,
    rules: [[String: Any]],
    ads: [String],
    clickScript: String,
    completion: @escaping FlutterResult
  ) {
    self.targetUrl = targetUrl
    self.headers = headers
    self.timeoutMs = timeoutMs
    self.ads = ads.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
    self.explicitClickScript = clickScript.trimmingCharacters(in: .whitespacesAndNewlines)

    var entries: [SniffRuleEntry] = []
    for raw in rules {
      let hosts = (raw["hosts"] as? [Any])?.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty } ?? []
      let regexStrs = (raw["regex"] as? [Any])?.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
      let excludeStrs = (raw["exclude"] as? [Any])?.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
      let click = ((raw["click"] as? String) ?? (raw["script"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let compiledRegexes = regexStrs.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
      let compiledExcludes = excludeStrs.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
      entries.append(SniffRuleEntry(
        hosts: hosts,
        regexPatterns: regexStrs,
        excludePatterns: excludeStrs,
        regexes: compiledRegexes,
        excludes: compiledExcludes,
        clickScript: click
      ))
    }
    self.parsedRules = entries

    self.effectiveUa = Self.desktopSafariUA
    for (k, v) in headers {
      if k.lowercased() == "user-agent" && !v.trimmingCharacters(in: .whitespaces).isEmpty && !v.lowercased().hasPrefix("okhttp/") {
        self.effectiveUa = v
        break
      }
    }
    self.completion = completion
    super.init()
    self.refreshMatchedRules(forHost: targetUrl.host ?? "")
  }

  static func sniff(
    urlString: String,
    headers: [String: String],
    timeoutMs: Int,
    completion: @escaping FlutterResult
  ) {
    sniff(
      urlString: urlString,
      headers: headers,
      timeoutMs: timeoutMs,
      rules: [],
      ads: [],
      clickScript: "",
      completion: completion
    )
  }

  static func sniff(
    urlString: String,
    headers: [String: String],
    timeoutMs: Int,
    rules: [[String: Any]] = [],
    ads: [String] = [],
    clickScript: String = "",
    completion: @escaping FlutterResult
  ) {
    DispatchQueue.main.async {
      guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = url.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            url.host != nil else {
        completion(nil)
        return
      }
      let instance = HeadlessMediaWebSniffer(
        targetUrl: url,
        headers: headers,
        timeoutMs: timeoutMs,
        rules: rules,
        ads: ads,
        clickScript: clickScript,
        completion: completion
      )
      activeSniffers.insert(instance)
      instance.start()
    }
  }

  static func clearAdBlockCache(completion: @escaping () -> Void) {
    DispatchQueue.main.async {
      compiledRuleCache.removeAll()
      guard let store = WKContentRuleListStore.default() else {
        completion()
        return
      }
      store.getAvailableContentRuleListIdentifiers { ids in
        guard let ids = ids, !ids.isEmpty else {
          completion()
          return
        }
        let group = DispatchGroup()
        for id in ids where id.hasPrefix("marco-ads-") {
          group.enter()
          store.removeContentRuleList(forIdentifier: id) { _ in
            group.leave()
          }
        }
        group.notify(queue: .main) {
          completion()
        }
      }
    }
  }

  private static func hostMatches(pattern: String, host: String) -> Bool {
    if pattern.isEmpty || pattern == "*" { return true }
    let lowerHost = host.lowercased()
    let lowerPat = pattern.lowercased()
    if lowerHost == lowerPat || lowerHost.hasSuffix("." + lowerPat) || lowerHost.contains(lowerPat) {
      return true
    }
    if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
      let range = NSRange(location: 0, length: lowerHost.utf16.count)
      if re.firstMatch(in: lowerHost, options: [], range: range) != nil {
        return true
      }
    }
    return false
  }

  private func matchedEntries(forHost host: String) -> [SniffRuleEntry] {
    return parsedRules.filter { entry in
      if entry.hosts.isEmpty { return true }
      return entry.hosts.contains { Self.hostMatches(pattern: $0, host: host) }
    }
  }

  private func refreshMatchedRules(forHost host: String) {
    let entries = matchedEntries(forHost: host)
    activeCustomRegexes = entries.flatMap { $0.regexes }
    activeExcludeRegexes = entries.flatMap { $0.excludes }
  }

  private func isAdOrExcluded(_ raw: String) -> Bool {
    let lower = raw.lowercased()
    let host = URL(string: raw)?.host?.lowercased()
    let rawRange = NSRange(location: 0, length: raw.utf16.count)
    for ad in ads {
      if ad.hasPrefix("regex:") {
        let body = String(ad.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty,
           let re = try? NSRegularExpression(pattern: body, options: [.caseInsensitive]),
           re.firstMatch(in: raw, options: [], range: rawRange) != nil {
          return true
        }
        continue
      }
      if let host = host, (host == ad || host.hasSuffix("." + ad) || lower.contains(ad)) {
        return true
      } else if lower.contains(ad) {
        return true
      }
    }
    for ex in activeExcludeRegexes {
      if ex.firstMatch(in: raw, options: [], range: rawRange) != nil {
        return true
      }
    }
    return false
  }

  private func looksLikePlayableMedia(_ raw: String) -> Bool {
    if isAdOrExcluded(raw) {
      return false
    }
    let nsRange = NSRange(location: 0, length: raw.utf16.count)
    for re in activeCustomRegexes {
      if re.firstMatch(in: raw, options: [], range: nsRange) != nil {
        return true
      }
    }
    let lower = raw.lowercased()
    if lower.range(of: #"\.(?:js|mjs|css|png|jpe?g|gif|webp|svg|ico|woff2?|ttf|json|xml|vtt|srt|html?|php)(?:$|[?#])"#, options: .regularExpression) != nil {
      return false
    }
    if lower.range(of: #"\.(?:m3u8?|mp4|flv|mkv|mpd|webm|m4v|mov)(?:$|[?#])"#, options: .regularExpression) != nil {
      return true
    }
    return lower.range(of: #"[?&](?:type|format|mime)=[^&#]*(?:m3u8|mp4|flv|mpegurl|video)"#, options: .regularExpression) != nil
  }

  private static func fnv1a64Hex(_ input: String) -> String {
    var hash: UInt64 = 14695981039346656037
    for byte in input.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 1099511628211
    }
    return String(format: "%016llx", hash)
  }

  private static func buildContentBlockerJson(for ads: [String]) -> (id: String, json: String)? {
    let normalized = Array(Set(ads.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter {
      !$0.isEmpty && $0 != "*" && $0 != "." && !$0.hasPrefix("regex:") && $0.unicodeScalars.allSatisfy { $0.isASCII }
    })).sorted()
    if normalized.isEmpty { return nil }

    var ruleObjects: [[String: Any]] = []
    let specialChars = CharacterSet(charactersIn: "^$.+?()[]{}|\\")
    for pattern in normalized.prefix(256) {
      var escaped = ""
      for scalar in pattern.unicodeScalars {
        if scalar == "*" {
          escaped += ".*"
        } else if specialChars.contains(scalar) {
          escaped += "\\" + String(scalar)
        } else {
          escaped += String(scalar)
        }
      }
      if pattern.contains("/") {
        ruleObjects.append([
          "trigger": ["url-filter": "^https?://[^/]*" + escaped],
          "action": ["type": "block"]
        ])
      } else {
        let hostPrefix = "^https?://([^/]+\\.)?" + escaped
        ruleObjects.append([
          "trigger": ["url-filter": hostPrefix + "[/:?#]"],
          "action": ["type": "block"]
        ])
        ruleObjects.append([
          "trigger": ["url-filter": hostPrefix + "$"],
          "action": ["type": "block"]
        ])
      }
    }
    guard !ruleObjects.isEmpty,
          let data = try? JSONSerialization.data(withJSONObject: ruleObjects, options: []),
          let jsonStr = String(data: data, encoding: .utf8) else {
      return nil
    }
    let identifier = "marco-ads-" + fnv1a64Hex(normalized.joined(separator: "|"))
    return (identifier, jsonStr)
  }

  private static func resolveContentRuleList(
    ads: [String],
    completion: @escaping (WKContentRuleList?) -> Void
  ) {
    guard let spec = buildContentBlockerJson(for: ads) else {
      completion(nil)
      return
    }
    if let cached = compiledRuleCache[spec.id] {
      completion(cached)
      return
    }
    let store = WKContentRuleListStore.default()
    store?.lookUpContentRuleList(forIdentifier: spec.id) { existing, _ in
      if let existing = existing {
        DispatchQueue.main.async {
          compiledRuleCache[spec.id] = existing
          completion(existing)
        }
        return
      }
      store?.compileContentRuleList(forIdentifier: spec.id, encodedContentRuleList: spec.json) { compiled, _ in
        DispatchQueue.main.async {
          if let compiled = compiled {
            compiledRuleCache[spec.id] = compiled
          }
          completion(compiled)
        }
      }
    }
  }

  private func start() {
    Self.resolveContentRuleList(ads: ads) { [weak self] ruleList in
      guard let self = self, !self.completed else { return }
      self.launchWebView(with: ruleList)
    }
  }

  private func launchWebView(with ruleList: WKContentRuleList?) {
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

    let matched = matchedEntries(forHost: targetUrl.host ?? "")
    let hookSource = Self.buildHookScript(
      customRegexPatterns: matched.flatMap { $0.regexPatterns },
      excludePatterns: matched.flatMap { $0.excludePatterns },
      adHosts: ads
    )

    let contentController = WKUserContentController()
    if let ruleList = ruleList {
      contentController.add(ruleList)
    }
    contentController.add(WeakSnifferScriptHandler(self), name: "marcoSniffer")
    contentController.addUserScript(
      WKUserScript(source: hookSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
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

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !completed else { return }
    let currentHost = webView.url?.host ?? targetUrl.host ?? ""
    refreshMatchedRules(forHost: currentHost)
    let matchedScripts = matchedEntries(forHost: currentHost)
      .map { $0.clickScript }
      .filter { !$0.isEmpty }
    var scriptsToRun = matchedScripts
    if !explicitClickScript.isEmpty && !scriptsToRun.contains(explicitClickScript) {
      scriptsToRun.append(explicitClickScript)
    }
    guard !scriptsToRun.isEmpty else { return }
    let combined = scriptsToRun.map { "try { \($0) } catch (_) {}" }.joined(separator: "\n")
    let wrapped = "(function(){ \(combined); if (window.__marcoScanDom) { window.__marcoScanDom(); } })();"
    webView.evaluateJavaScript(wrapped, completionHandler: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(450)) { [weak self, weak webView] in
      guard let self = self, !self.completed, let wv = webView else { return }
      wv.evaluateJavaScript(wrapped, completionHandler: nil)
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    let scheme = (url.scheme ?? "").lowercased()
    if scheme == "rtmp" || scheme == "rtsp" {
      if isAdOrExcluded(url.absoluteString) {
        decisionHandler(.cancel)
        return
      }
      completeWithMedia(url: url, referer: webView.url?.absoluteString ?? targetUrl.absoluteString)
      decisionHandler(.cancel)
      return
    }
    guard ["http", "https", "about", "blob", "data"].contains(scheme) else {
      decisionHandler(.cancel)
      return
    }
    if (scheme == "http" || scheme == "https") && isAdOrExcluded(url.absoluteString) {
      decisionHandler(.cancel)
      return
    }
    if (scheme == "http" || scheme == "https") && looksLikePlayableMedia(url.absoluteString) {
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
      if isAdOrExcluded(url.absoluteString) {
        decisionHandler(.cancel)
        return
      }
      let mime = (navigationResponse.response.mimeType ?? "").lowercased()
      if mime.contains("mpegurl") || mime.hasPrefix("video/") || mime.contains("dash+xml") || looksLikePlayableMedia(url.absoluteString) {
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
          looksLikePlayableMedia(mediaUrl.absoluteString) else {
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
    webView?.configuration.userContentController.removeAllContentRuleLists()
    webView?.configuration.userContentController.removeAllUserScripts()
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

@available(iOS 14.0, *)
private final class MarcoWebJsRedirectGuard: NSObject, URLSessionTaskDelegate {
  private let initialOrigin: (scheme: String, host: String, port: Int)

  init(initialUrl: URL) {
    let scheme = (initialUrl.scheme ?? "https").lowercased()
    let host = (initialUrl.host ?? "").lowercased()
    let port = initialUrl.port ?? (scheme == "https" ? 443 : 80)
    self.initialOrigin = (scheme, host, port)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let nextUrl = request.url,
          let nextScheme = nextUrl.scheme?.lowercased(),
          (nextScheme == "http" || nextScheme == "https"),
          let nextHost = nextUrl.host?.lowercased(),
          !nextHost.isEmpty else {
      completionHandler(nil)
      return
    }
    let nextPort = nextUrl.port ?? (nextScheme == "https" ? 443 : 80)
    let sameOrigin = (nextScheme == initialOrigin.scheme &&
                      nextHost == initialOrigin.host &&
                      nextPort == initialOrigin.port)
    if sameOrigin {
      completionHandler(request)
      return
    }
    var sanitized = request
    for header in ["authorization", "proxy-authorization", "cookie", "cookie2", "x-api-key"] {
      sanitized.setValue(nil, forHTTPHeaderField: header)
    }
    completionHandler(sanitized)
  }
}

@available(iOS 14.0, *)
private final class MarcoOffscreenWebJsHost: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
  static let shared = MarcoOffscreenWebJsHost()
  private static let maxBodyBytes = 6 * 1024 * 1024

  private struct PendingJob {
    let call: FlutterMethodCall
    let result: FlutterResult
  }

  private var webView: WKWebView?
  private var isReady = false
  private var isLoadingPage = false
  private var activeSessionKey: String?
  private var busy = false
  private var queue: [PendingJob] = []
  private var activeHttpTasks: [URLSessionDataTask] = []
  private var activeJobAbort: ((String) -> Void)?

  private static let bootstrapHtml = """
  <!DOCTYPE html>
  <html><head><meta charset="utf-8"></head><body></body></html>
  """

  private static let hostBridgeScript = """
  (function() {
    if (window.__marcoWebJsReady) return;
    window.__marcoWebJsReady = true;
    window.__marcoSpiders = Object.create(null);

    window.req = async function(url, options) {
      var opts = options && typeof options === 'object' ? options : {};
      var res = await window.webkit.messageHandlers.marcoJsHttp.postMessage({
        url: String(url || ''),
        options: opts
      });
      if (typeof res === 'string') return JSON.parse(res);
      return res || { code: 0, headers: {}, content: '' };
    };
    window.request = async function(url, options) {
      var res = await window.req(url, options);
      return res && res.content !== undefined ? String(res.content) : '';
    };
    window.getHtml = window.request;
    window.__movieCatvodBridge = window.__movieCatvodBridge || {
      request: function(url, options) { return window.req(url, options); }
    };

    window.__marcoSelectSpider = function(mod) {
      if (!mod) return null;
      if (typeof mod === 'function') return mod();
      if (mod.default) {
        if (typeof mod.default === 'function') return mod.default();
        if (typeof mod.default.__jsEvalReturn === 'function') return mod.default.__jsEvalReturn();
        return mod.default;
      }
      if (typeof mod.__jsEvalReturn === 'function') return mod.__jsEvalReturn();
      return mod;
    };

    window.__marcoInstantiateSpider = async function(entry, modules, extension, rawExtension) {
      var src = String((modules && modules[entry]) || '');
      if (!src) throw new Error('Missing JS entry module: ' + entry);
      var spider = null;
      var looksEsm = /(?:^|[;\\n])\\s*(?:export\\s+(?:default\\b|(?:async\\s+)?function\\b|const\\b|let\\b|var\\b|class\\b|\\u007b|\\*)|import\\s)/.test(src);
      if (looksEsm) {
        var resolved = src;
        if (modules) {
          resolved = src.replace(/(import\\s+[^'"]*?from\\s+|import\\s+)(['"])([^'"]+)\\2/g, function(full, prefix, q, spec) {
            try {
              var abs = new URL(spec, entry).href;
              if (Object.prototype.hasOwnProperty.call(modules, abs)) {
                var depBlob = new Blob([modules[abs]], { type: 'text/javascript' });
                return prefix + q + URL.createObjectURL(depBlob) + q;
              }
            } catch (_) {}
            return full;
          });
        }
        var blob = new Blob([resolved], { type: 'text/javascript' });
        var blobUrl = URL.createObjectURL(blob);
        try {
          var mod = await import(blobUrl);
          spider = window.__marcoSelectSpider(mod);
        } finally {
          URL.revokeObjectURL(blobUrl);
        }
      } else {
        var moduleObj = { exports: {} };
        var exportsObj = moduleObj.exports;
        var requireFn = function(spec) {
          var key = spec;
          try { key = new URL(spec, entry).href; } catch (_) {}
          var depSrc = modules && (modules[key] || modules[key + '.js'] || modules[spec]);
          if (!depSrc) throw new Error('Module not found: ' + spec);
          var m = { exports: {} };
          var f = new Function('module', 'exports', 'require', 'req', 'request', depSrc);
          f(m, m.exports, requireFn, window.req, window.request);
          return m.exports;
        };
        var fn = new Function(
          'module', 'exports', 'require', 'req', 'request',
          src + '\\n;if (typeof __jsEvalReturn === "function") return __jsEvalReturn(); return module.exports;'
        );
        var out = fn(moduleObj, exportsObj, requireFn, window.req, window.request);
        spider = window.__marcoSelectSpider(out);
      }
      if (!spider || typeof spider !== 'object') {
        throw new Error('Spider did not export an object');
      }
      if (typeof spider.init === 'function') {
        await Promise.resolve(spider.init(rawExtension !== undefined && rawExtension !== null ? rawExtension : extension));
      }
      return spider;
    };

    window.__marcoInvoke = async function(payload) {
      var key = payload.sessionKey || '__ephemeral__';
      var spider = payload.sessionKey ? window.__marcoSpiders[key] : null;
      if (!spider) {
        spider = await window.__marcoInstantiateSpider(
          payload.entry,
          payload.modules || {},
          payload.extension,
          payload.rawExtension
        );
        if (payload.sessionKey) {
          window.__marcoSpiders[key] = spider;
        }
      }
      var method = payload.method;
      var fn = spider[method];
      if (typeof fn !== 'function') {
        throw new Error('Spider missing method: ' + method);
      }
      var args = Array.isArray(payload.args) ? payload.args : [];
      if (payload.catDetails && method === 'detail') {
        args = [args];
      }
      var res = await Promise.resolve(fn.apply(spider, args));
      return typeof res === 'string' ? res : JSON.stringify(res);
    };
  })();
  """

  func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      switch call.method {
      case "invoke":
        self.queue.append(PendingJob(call: call, result: result))
        self.drainQueue()
      case "dispose", "reset":
        let args = call.arguments as? [String: Any]
        if let sessionKey = args?["sessionKey"] as? String, !sessionKey.isEmpty {
          let escaped = (try? String(data: JSONSerialization.data(withJSONObject: sessionKey, options: .fragmentsAllowed), encoding: .utf8)) ?? "\"\""
          self.webView?.evaluateJavaScript("if (window.__marcoSpiders) { delete window.__marcoSpiders[\(escaped)]; }", completionHandler: nil)
          if self.activeSessionKey == sessionKey {
            self.activeSessionKey = nil
          }
        } else {
          self.teardownWebView()
        }
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func ensureWebView(attempt: Int = 0, completion: @escaping (WKWebView?) -> Void) {
    if let wv = webView, isReady {
      completion(wv)
      return
    }
    if attempt >= 50 {
      completion(nil)
      return
    }
    if webView == nil {
      let config = WKWebViewConfiguration()
      config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
      config.allowsInlineMediaPlayback = true
      config.mediaTypesRequiringUserActionForPlayback = .all

      let ucc = WKUserContentController()
      ucc.addScriptMessageHandler(self, contentWorld: .page, name: "marcoJsHttp")
      ucc.addUserScript(
        WKUserScript(source: Self.hostBridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
      )
      config.userContentController = ucc

      let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
      wv.navigationDelegate = self
      self.webView = wv
      self.isReady = false
      self.isLoadingPage = true
      wv.loadHTMLString(Self.bootstrapHtml, baseURL: URL(string: "https://localhost.marco.invalid/"))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40)) { [weak self] in
      guard let self = self else {
        completion(nil)
        return
      }
      if self.isReady, let wv = self.webView {
        completion(wv)
      } else {
        self.ensureWebView(attempt: attempt + 1, completion: completion)
      }
    }
  }

  private func teardownWebView(reason: String? = nil) {
    let abort = activeJobAbort
    activeJobAbort = nil
    for task in activeHttpTasks {
      task.cancel()
    }
    activeHttpTasks.removeAll()
    if let wv = webView {
      wv.configuration.userContentController.removeScriptMessageHandler(forName: "marcoJsHttp", contentWorld: .page)
      wv.configuration.userContentController.removeAllUserScripts()
      wv.stopLoading()
      wv.navigationDelegate = nil
    }
    webView = nil
    isReady = false
    isLoadingPage = false
    activeSessionKey = nil
    if let reason = reason {
      abort?(reason)
    }
  }

  private func drainQueue() {
    guard !busy, !queue.isEmpty else { return }
    busy = true
    let job = queue.removeFirst()
    executeInvoke(job: job) { [weak self] in
      guard let self = self else { return }
      self.busy = false
      self.drainQueue()
    }
  }

  private func executeInvoke(job: PendingJob, done: @escaping () -> Void) {
    guard let args = job.call.arguments as? [String: Any] else {
      job.result(FlutterError(code: "invalid_request", message: "Missing webview_js arguments", details: nil))
      done()
      return
    }
    ensureWebView { [weak self] wv in
      guard let self = self, let wv = wv else {
        job.result(FlutterError(code: "webview_unavailable", message: "Offscreen WKWebView unavailable", details: nil))
        done()
        return
      }
      let timeoutMs = min(max((args["timeoutMs"] as? Int) ?? 12000, 1000), 45000)
      var finished = false
      func finish(_ value: Any?, _ error: FlutterError?) {
        guard !finished else { return }
        finished = true
        self.activeJobAbort = nil
        if let err = error {
          job.result(err)
        } else {
          job.result(value)
        }
        done()
      }

      self.activeJobAbort = { reason in
        finish(nil, FlutterError(code: "webview_terminated", message: reason, details: nil))
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
        finish(nil, FlutterError(code: "timeout", message: "Offscreen WebView JS timeout", details: nil))
      }

      self.activeSessionKey = args["sessionKey"] as? String
      wv.callAsyncJavaScript(
        "return await window.__marcoInvoke(payload);",
        arguments: ["payload": args],
        in: nil,
        in: .page
      ) { outcome in
        switch outcome {
        case .success(let value):
          if let str = value as? String {
            finish(str, nil)
          } else if JSONSerialization.isValidJSONObject(value),
                    let data = try? JSONSerialization.data(withJSONObject: value, options: []),
                    let jsonStr = String(data: data, encoding: .utf8) {
            finish(jsonStr, nil)
          } else {
            finish("", nil)
          }
        case .failure(let error):
          finish(nil, FlutterError(code: "js_error", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    if webView === self.webView {
      isReady = true
      isLoadingPage = false
    }
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    if webView === self.webView {
      teardownWebView(reason: "WKWebView WebContent process terminated")
      // Rebuild a fresh offscreen WKWebView immediately so next call is warm.
      ensureWebView { _ in }
    }
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage,
    replyHandler: @escaping (Any?, String?) -> Void
  ) {
    guard message.name == "marcoJsHttp",
          let body = message.body as? [String: Any],
          let rawUrl = body["url"] as? String,
          let url = URL(string: rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = url.scheme?.lowercased(),
          (scheme == "http" || scheme == "https"),
          url.host != nil else {
      replyHandler(nil, "Invalid HTTP bridge request URL")
      return
    }

    let opts = (body["options"] as? [String: Any]) ?? [:]
    let method = ((opts["method"] as? String) ?? "GET").uppercased()
    guard ["GET", "POST", "HEAD", "PUT", "PATCH", "DELETE", "OPTIONS"].contains(method) else {
      replyHandler(nil, "Unsupported HTTP method: \(method)")
      return
    }

    let timeoutMs = min(max((opts["timeout"] as? Int) ?? 10000, 500), 25000)
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Double(timeoutMs) / 1000.0)
    req.httpMethod = method
    req.setValue("okhttp/3.15", forHTTPHeaderField: "User-Agent")
    if let headers = opts["headers"] as? [String: Any] {
      for (k, v) in headers {
        req.setValue("\(v)", forHTTPHeaderField: k)
      }
    }
    if let bodyBase64 = opts["bodyBase64"] as? String,
       let data = Data(base64Encoded: bodyBase64),
       data.count <= Self.maxBodyBytes {
      req.httpBody = data
    } else if let bodyStr = opts["data"] as? String ?? opts["body"] as? String {
      req.httpBody = bodyStr.data(using: .utf8)
    } else if let bodyObj = opts["data"] ?? opts["body"],
              JSONSerialization.isValidJSONObject(bodyObj),
              let data = try? JSONSerialization.data(withJSONObject: bodyObj, options: []) {
      req.httpBody = data
    }

    let returnBase64 = (opts["buffer"] as? Int) == 2
    let redirectGuard = MarcoWebJsRedirectGuard(initialUrl: url)
    let sessionConfig = URLSessionConfiguration.ephemeral
    sessionConfig.timeoutIntervalForRequest = Double(timeoutMs) / 1000.0
    sessionConfig.timeoutIntervalForResource = Double(timeoutMs) / 1000.0 + 5.0
    sessionConfig.httpCookieAcceptPolicy = .never
    sessionConfig.httpShouldSetCookies = false
    let scopedSession = URLSession(configuration: sessionConfig, delegate: redirectGuard, delegateQueue: nil)

    var task: URLSessionDataTask?
    task = scopedSession.dataTask(with: req) { [weak self] data, response, error in
      scopedSession.finishTasksAndInvalidate()
      DispatchQueue.main.async {
        if let t = task {
          self?.activeHttpTasks.removeAll { $0 === t }
        }
        if let error = error {
          replyHandler(nil, error.localizedDescription)
          return
        }
        let httpResp = response as? HTTPURLResponse
        let status = httpResp?.statusCode ?? 0
        let payload = data ?? Data()
        if payload.count > Self.maxBodyBytes {
          replyHandler(nil, "HTTP response body exceeds 6 MiB limit")
          return
        }
        var respHeaders: [String: String] = [:]
        if let allHeaders = httpResp?.allHeaderFields {
          for (k, v) in allHeaders {
            respHeaders["\(k)"] = "\(v)"
          }
        }
        let contentValue = returnBase64
          ? payload.base64EncodedString()
          : (String(data: payload, encoding: .utf8) ?? String(decoding: payload, as: UTF8.self))
        replyHandler([
          "code": status,
          "url": httpResp?.url?.absoluteString ?? url.absoluteString,
          "headers": respHeaders,
          "content": contentValue
        ], nil)
      }
    }
    if let t = task {
      DispatchQueue.main.async {
        self.activeHttpTasks.append(t)
      }
      t.resume()
    } else {
      scopedSession.finishTasksAndInvalidate()
      replyHandler(nil, "Failed to create HTTP bridge task")
    }
  }
}
