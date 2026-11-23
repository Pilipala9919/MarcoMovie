#ifndef MARCO_WEBVIEW2_PLUGIN_H_
#define MARCO_WEBVIEW2_PLUGIN_H_

#include <windows.h>

#include <memory>

namespace flutter {
class BinaryMessenger;
}  // namespace flutter

namespace marco {

// Lightweight native Windows Edge WebView2 plugin providing:
// 1. `marco_movie/web_sniffer` - Stage-3 headless muted WebView2 media sniffer
//    with 204 ad blocking, custom rule matching, header/cookie capture, and
//    click-script injection.
// 2. `marco_movie/webview_js` - Lazy off-screen async JS/DRPY2 fallback engine
//    with PostWebMessageAsJson <-> Dart HTTP bridging and idle auto-sleep.
//
// Zero NuGet / Fixed Runtime build dependency: dynamically loads
// WebView2Loader.dll or probes Evergreen Edge WebView2 Runtime
// (EmbeddedBrowserWebView.dll) via Windows Registry and degrades silently with
// `available: false` / `null` on stripped Windows LTSC systems.
class MarcoWebview2Plugin {
 public:
  explicit MarcoWebview2Plugin(flutter::BinaryMessenger* messenger,
                               HWND parent_window = nullptr);
  ~MarcoWebview2Plugin();

  MarcoWebview2Plugin(const MarcoWebview2Plugin&) = delete;
  MarcoWebview2Plugin& operator=(const MarcoWebview2Plugin&) = delete;

  // Releases active sniffer sessions, offscreen JS host, timers, and hidden
  // helper windows. Safe to call multiple times from FlutterWindow::OnDestroy().
  void Shutdown();

  // Returns true if Edge WebView2 Runtime is available and loadable on this
  // system. Never throws or displays modal UI.
  bool IsAvailable() const;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace marco

#endif  // MARCO_WEBVIEW2_PLUGIN_H_
