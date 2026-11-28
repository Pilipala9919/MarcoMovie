"""Unit tests for prepare_platform.py macOS Runner generation."""
from pathlib import Path
import shutil
import tempfile
import unittest

import prepare_platform


SAMPLE_MAIN_FLUTTER_WINDOW = """import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
"""

SAMPLE_ENTITLEMENTS = """<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>
  <true/>
</dict>
</plist>
"""

SAMPLE_INFO_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>marco_movie</string>
</dict>
</plist>
"""

SAMPLE_PODFILE = "# platform :osx, '10.14'\n"
SAMPLE_PBXPROJ = "MACOSX_DEPLOYMENT_TARGET = 10.14;\n"


class PrepareMacosRunnerTests(unittest.TestCase):
    def test_macos_runner_window_memory_and_idempotency(self):
        with tempfile.TemporaryDirectory(prefix="marco-macos-runner-") as tmp:
            fake_root = Path(tmp) / "flutter"
            runner = fake_root / "macos" / "Runner"
            runner.mkdir(parents=True)
            (fake_root / "macos" / "Podfile").write_text(SAMPLE_PODFILE, encoding="utf-8")
            pbx = fake_root / "macos" / "Runner.xcodeproj" / "project.pbxproj"
            pbx.parent.mkdir(parents=True)
            pbx.write_text(SAMPLE_PBXPROJ, encoding="utf-8")
            window_swift = runner / "MainFlutterWindow.swift"
            window_swift.write_text(SAMPLE_MAIN_FLUTTER_WINDOW, encoding="utf-8")
            (runner / "Release.entitlements").write_text(SAMPLE_ENTITLEMENTS, encoding="utf-8")
            (runner / "DebugProfile.entitlements").write_text(SAMPLE_ENTITLEMENTS, encoding="utf-8")
            (runner / "Info.plist").write_text(SAMPLE_INFO_PLIST, encoding="utf-8")

            orig_root = prepare_platform.ROOT
            try:
                prepare_platform.ROOT = fake_root
                prepare_platform.main()
                first_pass = window_swift.read_text(encoding="utf-8")
                prepare_platform.main()
                second_pass = window_swift.read_text(encoding="utf-8")
            finally:
                prepare_platform.ROOT = orig_root

            self.assertEqual(first_pass, second_pass, "prepare_platform.py must be idempotent")
            self.assertIn("NSSize(width: 720, height: 520)", first_pass)
            self.assertNotIn("NSSize(width: 900, height: 600)", first_pass)
            awake_block = first_pass.split("extension MainFlutterWindow {", 1)[0]
            self.assertNotIn(
                "self.appearance = NSAppearance(named: .darkAqua)",
                awake_block,
                "awakeFromNib must not hardcode darkAqua so Light Mode titlebars work",
            )
            self.assertIn("NSAppearance(named: .aqua)", first_pass)
            self.assertLess(
                first_pass.index("self.marcoRestoreInitialFrame()"),
                first_pass.index("super.awakeFromNib()"),
                "Saved normal bounds must be restored before first display",
            )
            for required in (
                'marco_movie/macos_window',
                'marco_macos_window_frame_v1',
                'self.isRestorable = false',
                'didMoveNotification',
                'didResizeNotification',
                'didEndLiveResizeNotification',
                'willEnterFullScreenNotification',
                'didExitFullScreenNotification',
                'willMiniaturizeNotification',
                'didDeminiaturizeNotification',
                'willCloseNotification',
                'willTerminateNotification',
                'didChangeScreenParametersNotification',
                'marcoEnsureWindowChromeVisible',
                'activateFileViewerSelecting',
                'setAppearance',
            ):
                self.assertIn(required, first_pass)

            ent = (runner / "Release.entitlements").read_text(encoding="utf-8")
            for key in (
                "com.apple.security.network.client",
                "com.apple.security.network.server",
                "com.apple.security.files.downloads.read-write",
                "com.apple.security.files.user-selected.read-write",
            ):
                self.assertIn(key, ent)
            self.assertIn("platform :osx, '11.0'", (fake_root / "macos" / "Podfile").read_text(encoding="utf-8"))
            self.assertIn("MACOSX_DEPLOYMENT_TARGET = 11.0;", pbx.read_text(encoding="utf-8"))
            self.assertTrue((fake_root / "assets" / "logo_mark.png").is_file())

    def test_legacy_4429808_runner_double_upgrade_and_release_entitlements_strip(self):
        legacy_swift = """import Cocoa
import FlutterMacOS
import WebKit

class MainFlutterWindow: NSWindow {
  private var playbackActivity: NSObjectProtocol?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let wakelockChannel = FlutterMethodChannel(name: "marco_movie/wakelock", binaryMessenger: flutterViewController.engine.binaryMessenger)
    wakelockChannel.setMethodCallHandler { [weak self] call, result in
      if call.method == "setEnabled", let enabled = call.arguments as? Bool {
        if enabled {
          if self?.playbackActivity == nil {
            self?.playbackActivity = ProcessInfo.processInfo.beginActivity(options: .idleDisplaySleepDisabled, reason: "Marco Movie Video Playback")
          }
        } else if let token = self?.playbackActivity {
          ProcessInfo.processInfo.endActivity(token)
          self?.playbackActivity = nil
        }
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)
    self.appearance = NSAppearance(named: .darkAqua)
    self.minSize = NSSize(width: 900, height: 600)
    super.awakeFromNib()
  }
}
"""
        release_with_debug = """<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>
  <true/>
  <key>com.apple.security.get-task-allow</key>
  <true/>
</dict>
</plist>
"""
        with tempfile.TemporaryDirectory(prefix="marco-macos-legacy-runner-") as tmp:
            fake_root = Path(tmp) / "flutter"
            runner = fake_root / "macos" / "Runner"
            runner.mkdir(parents=True)
            window_swift = runner / "MainFlutterWindow.swift"
            window_swift.write_text(legacy_swift, encoding="utf-8")
            (runner / "Release.entitlements").write_text(release_with_debug, encoding="utf-8")
            (runner / "DebugProfile.entitlements").write_text(release_with_debug, encoding="utf-8")
            (runner / "Info.plist").write_text(SAMPLE_INFO_PLIST, encoding="utf-8")

            orig_root = prepare_platform.ROOT
            try:
                prepare_platform.ROOT = fake_root
                prepare_platform.main()
                first_pass = window_swift.read_text(encoding="utf-8")
                prepare_platform.main()
                second_pass = window_swift.read_text(encoding="utf-8")
            finally:
                prepare_platform.ROOT = orig_root

            self.assertEqual(first_pass, second_pass, "Double upgrade of 4429808 Runner must be idempotent")
            for field in (
                "private var playbackActivity: NSObjectProtocol?",
                "private var marcoWindowObservers: [NSObjectProtocol] = []",
                "private var marcoInFullscreenTransition = false",
                "private var marcoIsMiniaturizing = false",
                "private var marcoIsClosing = false",
                "private var marcoRestoredFromSaved = false",
                "private var marcoLastNormalFrame: NSRect?",
                "private var marcoWindowChannel: FlutterMethodChannel?",
                "deinit {",
            ):
                self.assertEqual(
                    second_pass.count(field),
                    1,
                    f"Expected {field!r} exactly once after upgrading 4429808 Runner",
                )
            for required in (
                "import CoreVideo",
                "getDisplayRefreshInfo",
                "onDisplayRefreshRateChanged",
                "didChangeScreenNotification",
                "MarcoMovieDisplayChanged",
                "pickLocalFile",
                "NSOpenPanel",
                "startAccessingSecurityScopedResource",
                "marcoFlushLastNormalFrameOnTerminate",
                "screens.first?.visibleFrame",
            ):
                self.assertIn(required, second_pass)
            self.assertNotIn("NSSize(width: 900, height: 600)", second_pass)
            self.assertIn("NSSize(width: 720, height: 520)", second_pass)
            awake_block = second_pass.split("extension MainFlutterWindow {", 1)[0]
            self.assertNotIn("NSAppearance(named: .darkAqua)", awake_block)
            # Cold start without saved record must not leak centered default frame as savedFrame
            self.assertIn("self.marcoLastNormalFrame = (saved != nil) ? resolved : nil", second_pass)
            self.assertIn(
                "Self.marcoLoadSavedFrame() ?? (self.marcoRestoredFromSaved ? self.marcoLastNormalFrame : nil)",
                second_pass,
            )
            rel_ent = (runner / "Release.entitlements").read_text(encoding="utf-8")
            dbg_ent = (runner / "DebugProfile.entitlements").read_text(encoding="utf-8")
            self.assertNotIn("com.apple.security.get-task-allow", rel_ent)
            self.assertIn("com.apple.security.get-task-allow", dbg_ent)

    def test_media_kit_video_cvdisplaylink_vsync_patch_idempotency(self):
        sample_texture_hw = """import FlutterMacOS
import OpenGL.GL
import OpenGL.GL3
public class TextureHW: NSObject {}
"""
        sample_video_output = """import FlutterMacOS
public class VideoOutput: NSObject {
  private var texture: ResizableTextureProtocol!
  private var disposed: Bool = false
  private func _init() {
    if enableHardwareAcceleration {
      texture = SafeResizableTexture(
        TextureHW(
          handle: handle,
          // Use `weak self` to prevent memory leaks
          updateCallback: { [weak self]() in
            guard let that = self else {
              return
            }
            that.updateCallback()
          }
        )
      )
    }
  }
  private func _updateCallback() {
    let size = videoSize

    if size.width == 0 || size.height == 0 {
      return
    }
    texture.render(size)
    DispatchQueue.main.sync { [weak self] in
      guard let that = self else { return }
      that.registry.textureFrameAvailable(that.textureId)
    }
  }
}
"""
        with tempfile.TemporaryDirectory(prefix="marco-mk-vsync-") as tmp:
            plugin_macos = Path(tmp) / "media_kit_video" / "macos"
            hw_path = plugin_macos / "Classes" / "plugin" / "TextureHW.swift"
            vo_path = plugin_macos / "Classes" / "plugin" / "common" / "VideoOutput.swift"
            hw_path.parent.mkdir(parents=True)
            vo_path.parent.mkdir(parents=True)
            hw_path.write_text(sample_texture_hw, encoding="utf-8")
            vo_path.write_text(sample_video_output, encoding="utf-8")

            changed_first = prepare_platform.patch_macos_media_kit_video_vsync(plugin_macos)
            self.assertTrue(changed_first)
            hw_first = hw_path.read_text(encoding="utf-8")
            vo_first = vo_path.read_text(encoding="utf-8")

            changed_second = prepare_platform.patch_macos_media_kit_video_vsync(plugin_macos)
            self.assertFalse(changed_second, "Second vsync patch pass must be a no-op")
            self.assertEqual(hw_first, hw_path.read_text(encoding="utf-8"))
            self.assertEqual(vo_first, vo_path.read_text(encoding="utf-8"))

            for token in (
                "CVDisplayLink",
                "MPV_RENDER_PARAM_ADVANCED_CONTROL",
                "mpv_render_context_update",
                "MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME",
                "mpv_render_context_report_swap",
                "MARCO_MPV_VSYNC_PACED",
                "MarcoMovieDisplayChanged",
                "endVsyncTick",
                "drainPendingUpdateWithoutRender",
            ):
                self.assertIn(token, hw_first)
            for token in (
                "private weak var hwTexture: TextureHW?",
                "hwTexture?.endVsyncTick()",
                "hwTexture?.drainPendingUpdateWithoutRender()",
                "lastRenderProducedFrame",
            ):
                self.assertIn(token, vo_first)

    def test_macos_bundle_and_menu_display_name_is_marcomovie(self):
        with tempfile.TemporaryDirectory(prefix="marco-macos-name-") as tmp:
            fake_root = Path(tmp) / "flutter"
            runner = fake_root / "macos" / "Runner"
            (runner / "Configs").mkdir(parents=True)
            (runner / "Base.lproj").mkdir(parents=True)
            xcscheme_dir = fake_root / "macos" / "Runner.xcodeproj" / "xcshareddata" / "xcschemes"
            xcscheme_dir.mkdir(parents=True)
            pbx = fake_root / "macos" / "Runner.xcodeproj" / "project.pbxproj"
            pbx.write_text(
                'path = "marco_movie.app";\n'
                'TEST_HOST = "$(BUILT_PRODUCTS_DIR)/marco_movie.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/marco_movie";\n'
                'MACOSX_DEPLOYMENT_TARGET = 10.14;\n',
                encoding="utf-8",
            )
            xcscheme = xcscheme_dir / "Runner.xcscheme"
            xcscheme.write_text('BuildableName = "marco_movie.app"\n', encoding="utf-8")
            app_info = runner / "Configs" / "AppInfo.xcconfig"
            app_info.write_text(
                "PRODUCT_NAME = marco_movie\n"
                "PRODUCT_BUNDLE_IDENTIFIER = com.example.marcoMovie\n",
                encoding="utf-8",
            )
            main_menu = runner / "Base.lproj" / "MainMenu.xib"
            main_menu.write_text(
                '<menuItem title="APP_NAME"/><menuItem title="Quit APP_NAME"/><window title="APP_NAME"/>',
                encoding="utf-8",
            )
            info_plist = runner / "Info.plist"
            info_plist.write_text(
                '<?xml version="1.0" encoding="UTF-8"?>\n'
                '<plist version="1.0">\n<dict>\n'
                '  <key>CFBundleName</key>\n  <string>$(PRODUCT_NAME)</string>\n'
                '</dict>\n</plist>\n',
                encoding="utf-8",
            )
            (runner / "MainFlutterWindow.swift").write_text(SAMPLE_MAIN_FLUTTER_WINDOW, encoding="utf-8")

            orig_root = prepare_platform.ROOT
            try:
                prepare_platform.ROOT = fake_root
                prepare_platform.main()
                first_cfg = app_info.read_text(encoding="utf-8")
                first_plist = info_plist.read_text(encoding="utf-8")
                first_xib = main_menu.read_text(encoding="utf-8")
                first_pbx = pbx.read_text(encoding="utf-8")
                first_scheme = xcscheme.read_text(encoding="utf-8")
                prepare_platform.main()
            finally:
                prepare_platform.ROOT = orig_root

            self.assertEqual(first_cfg, app_info.read_text(encoding="utf-8"))
            self.assertEqual(first_plist, info_plist.read_text(encoding="utf-8"))
            self.assertEqual(first_xib, main_menu.read_text(encoding="utf-8"))
            self.assertEqual(first_pbx, pbx.read_text(encoding="utf-8"))
            self.assertEqual(first_scheme, xcscheme.read_text(encoding="utf-8"))

            self.assertIn("PRODUCT_NAME = MarcoMovie", first_cfg)
            self.assertIn("PRODUCT_BUNDLE_IDENTIFIER = com.example.marcoMovie", first_cfg)
            self.assertIn("<key>CFBundleDisplayName</key>\n  <string>MarcoMovie</string>", first_plist)
            self.assertNotIn("APP_NAME", first_xib)
            self.assertIn('title="MarcoMovie"', first_xib)
            self.assertIn('title="Quit MarcoMovie"', first_xib)
            self.assertIn('path = "MarcoMovie.app";', first_pbx)
            self.assertIn('$(BUNDLE_EXECUTABLE_FOLDER_PATH)/MarcoMovie', first_pbx)
            self.assertIn('BuildableName = "MarcoMovie.app"', first_scheme)


if __name__ == "__main__":
    unittest.main()
