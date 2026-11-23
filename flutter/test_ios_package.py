"""Deployment guard regression tests; these do not replace a device launch test."""
import plistlib
import re
import struct
import tempfile
import unittest
from unittest.mock import patch
import prepare_platform
from pathlib import Path
from patch_ios_ipa import validate_app


class DeploymentChecks(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.app = Path(self.folder.name)
        (self.app / 'Info.plist').write_bytes(plistlib.dumps({'MinimumOSVersion': '15.0'}))

    def binary(self, minimum, platform=2, filetype=2):
        return struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, filetype, 1, 24, 0, 0) + struct.pack('<6I', 0x32, 24, platform, minimum, 0x1a0000, 0)

    def test_real_compatible_deployment_is_unchanged(self):
        for minos in (0x0e0000, 0x0f0000):
            blob = self.binary(minos)
            (self.app / 'Runner').write_bytes(blob)
            validate_app(self.app)
            self.assertEqual((self.app / 'Runner').read_bytes(), blob)

    def test_dsym_or_object_macho_rejected(self):
        for bad_type in (1, 10):
            (self.app / 'Runner').write_bytes(self.binary(0x0f0000, filetype=bad_type))
            with self.assertRaises(ValueError):
                validate_app(self.app)

    def test_new_engine_is_rejected_instead_of_forging_minimum(self):
        blob = self.binary(0x100000)
        (self.app / 'Runner').write_bytes(blob)
        with self.assertRaises(ValueError):
            validate_app(self.app)
        self.assertEqual((self.app / 'Runner').read_bytes(), blob)

    def test_simulator_binary_rejected(self):
        (self.app / 'Runner').write_bytes(self.binary(0x0e0000, 7))
        with self.assertRaises(ValueError):
            validate_app(self.app)

    def test_truncated_binary_rejected(self):
        (self.app / 'Runner').write_bytes(self.binary(0x0e0000)[:-4])
        with self.assertRaises(ValueError):
            validate_app(self.app)

    def test_empty_bundle_rejected(self):
        with self.assertRaises(ValueError):
            validate_app(self.app)

    def test_platform_settings_are_written_at_plist_root(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            runner = root / 'ios/Runner'
            runner.mkdir(parents=True)
            plist = runner / 'Info.plist'
            nested = {'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': True}}
            plist.write_bytes(plistlib.dumps(nested))
            with patch.object(prepare_platform, 'ROOT', root):
                prepare_platform.main()
            result = plistlib.loads(plist.read_bytes())
            self.assertIn('NSLocalNetworkUsageDescription', result)
            self.assertTrue(result['NSAppTransportSecurity']['NSAllowsArbitraryLoads'])
            self.assertEqual(result['UIApplicationSceneManifest'], nested['UIApplicationSceneManifest'])
            self.assertIs(result['FlutterDeepLinkingEnabled'], False)
            for scheme in ('qklink', 'qkcloudlink', 'uclink', 'ucliteioslink', 'bdnetdisk', 'baiduyunipad', 'baiduboxapp', 'smartdrive', 'alipan', 'tbopen'):
                self.assertIn(scheme, result['LSApplicationQueriesSchemes'])
            url_types = result['CFBundleURLTypes']
            self.assertEqual(len([u for u in url_types if 'marcomovie' in u.get('CFBundleURLSchemes', [])]), 1)

    def test_ios_app_delegate_injects_wakelock_and_netdisk_auth_idempotently(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            runner = root / 'ios/Runner'
            runner.mkdir(parents=True)
            flutter_ios = root / 'ios/Flutter'
            flutter_ios.mkdir(parents=True)
            (flutter_ios / 'AppFrameworkInfo.plist').write_bytes(plistlib.dumps({'MinimumOSVersion': '14.0'}))
            (flutter_ios / 'Release.xcconfig').write_text('IPHONEOS_DEPLOYMENT_TARGET = 13.0\n', encoding='utf-8')
            xcodeproj = root / 'ios/Runner.xcodeproj'
            xcodeproj.mkdir(parents=True)
            (xcodeproj / 'project.pbxproj').write_text('IPHONEOS_DEPLOYMENT_TARGET = 13.0;\n', encoding='utf-8')
            (runner / 'Info.plist').write_bytes(plistlib.dumps({
                'MinimumOSVersion': '15.0',
                'UIBackgroundModes': ['fetch'],
            }))
            app_delegate = runner / 'AppDelegate.swift'
            app_delegate.write_text(
                'import Flutter\n'
                'import UIKit\n\n'
                '@main\n'
                '@objc class AppDelegate: FlutterAppDelegate {\n'
                '  override func application(\n'
                '    _ application: UIApplication,\n'
                '    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?\n'
                '  ) -> Bool {\n'
                '    GeneratedPluginRegistrant.register(with: self)\n'
                '    return super.application(application, didFinishLaunchingWithOptions: launchOptions)\n'
                '  }\n'
                '}\n',
                encoding='utf-8',
            )
            with patch.object(prepare_platform, 'ROOT', root):
                prepare_platform.main()
                prepare_platform.main()
                prepare_platform.main()
            swift = app_delegate.read_text(encoding='utf-8')
            self.assertEqual(swift.count('import WebKit'), 1)
            self.assertEqual(len(re.findall(r'(?m)^import AVKit$', swift)), 1)
            self.assertEqual(len(re.findall(r'(?m)^import AVFoundation$', swift)), 1)
            self.assertEqual(swift.count('marco_movie/wakelock'), 1)
            self.assertEqual(swift.count('marco_movie/netdisk_auth'), 1)
            self.assertEqual(swift.count('"marco_movie/web_sniffer"'), 1)
            self.assertEqual(swift.count('"marco_movie/webview_js"'), 1)
            self.assertEqual(swift.count('MarcoLiquidGlassPlugin'), 1)
            self.assertEqual(swift.count('MarcoAvPlayerPlugin'), 1)
            self.assertEqual(swift.count('enum MarcoAvPlayerEngine'), 1)
            self.assertEqual(swift.count('"marco_movie/ios_avplayer"'), 1)
            self.assertEqual(swift.count('"marco_movie/ios_avplayer_view"'), 1)
            self.assertEqual(swift.count('private enum MarcoWebSnifferAndJsHostRegistrar'), 1)
            self.assertEqual(swift.count('private final class MarcoOffscreenWebJsHost'), 1)
            self.assertIn('AVPictureInPictureController', swift)
            self.assertIn('canStartPictureInPictureAutomaticallyFromInline', swift)
            self.assertIn('WKContentRuleList', swift)
            self.assertIn('WKScriptMessageHandlerWithReply', swift)
            self.assertEqual(swift.count('private enum MarcoLiquidGlassSupport'), 1)
            self.assertEqual(swift.count('"marco_movie/ios26_dock"'), 1)
            self.assertEqual(swift.count('"marco_movie/ios26_glass_button"'), 1)
            self.assertEqual(swift.count('"marco_movie/ios26_glass_pill"'), 1)
            self.assertEqual(swift.count('"marco_movie/ios26_segmented_control"'), 1)
            self.assertEqual(swift.count('"marco_movie/ios26_switch"'), 1)
            self.assertEqual(swift.count('"marco_movie/ios26_slider"'), 1)
            self.assertEqual(swift.count('final class MarcoNativeSwitchFactory'), 1)
            self.assertEqual(swift.count('final class MarcoNativeSliderFactory'), 1)
            self.assertEqual(swift.count('final class MarcoIos27RootTabChromeController'), 1)
            self.assertEqual(swift.count('final class MarcoIos27PassthroughChromeView'), 1)
            self.assertEqual(swift.count('final class MarcoIos27DockChromeView'), 1)
            self.assertEqual(swift.count('final class MarcoNativeGlassButtonControl'), 1)
            self.assertEqual(swift.count('static func withoutAnimations'), 1)
            self.assertEqual(swift.count('final class MarcoNativeFilterSheetController'), 1)
            self.assertEqual(swift.count('case "showFilterSheet":'), 1)
            self.assertEqual(swift.count('final class MarcoNativePinSheetController'), 1)
            self.assertEqual(swift.count('case "showPrivacyPin":'), 1)
            self.assertEqual(swift.count('case "configureRootTabChrome":'), 1)
            self.assertEqual(swift.count('case "setRootTabSelectedIndex":'), 1)
            self.assertEqual(swift.count('case "setRootTabMinimized":'), 1)
            self.assertEqual(swift.count('case "setRootTabVisible":'), 1)
            self.assertEqual(swift.count('case "showMenuAtRect":'), 1)
            self.assertEqual(swift.count('final class MarcoNativeLiquidTabCapsuleView'), 1)
            self.assertEqual(swift.count('final class MarcoAnimatedTabIconView'), 1)
            self.assertIn('UITabBarDelegate', swift)
            self.assertIn('UITabBarItem(', swift)
            self.assertIn('UIGlassContainerEffect()', swift)
            self.assertIn('UIButton.Configuration.glass()', swift)
            self.assertIn('UIButton.Configuration.prominentGlass()', swift)
            self.assertIn('cornerConfiguration = .capsule()', swift)
            self.assertIn('containerConcentric(', swift)
            self.assertIn('UISpringTimingParameters(duration: duration, bounce: bounce)', swift)
            self.assertIn('animateSpring(duration: 0.38, bounce: 0.16', swift)
            self.assertIn('addSymbolEffect(.bounce', swift)
            self.assertIn('UIScene.didActivateNotification', swift)
            self.assertIn('UIScene.willDeactivateNotification', swift)
            self.assertIn('final class MarcoTraitAwareHostView', swift)
            self.assertIn('static func adaptiveGlassForeground', swift)
            self.assertIn('static func isNearBlack', swift)
            self.assertNotIn('scaleX: 0.93', swift)
            self.assertNotIn('scaleX: 0.95', swift)
            self.assertNotIn('MarcoInteractiveCircleGlassControl', swift)
            self.assertNotIn('updateNativeGlassIntensity', swift)
            self.assertNotIn('UIScreen.main.bounds', swift)
            self.assertNotIn('UIScreen.main.scale', swift)
            self.assertEqual(
                [line for line in swift.splitlines() if not line.lstrip().startswith('//') and 'UIScreen.main' in line],
                [],
            )
            self.assertIn('static func activeWindowBounds', swift)
            self.assertEqual(swift.count('final class NetdiskWebAuthController'), 1)
            self.assertEqual(swift.count('private final class HeadlessMediaWebSniffer'), 1)
            self.assertEqual(swift.count('case "discoverBonjourDevices":'), 1)
            self.assertEqual(swift.count('private final class MarcoBonjourScanner'), 1)
            self.assertEqual(swift.count('{'), swift.count('}'))
            plist = plistlib.loads((runner / 'Info.plist').read_bytes())
            self.assertIs(plist['UIRequiresFullScreen'], False)
            self.assertIn('UIApplicationSceneManifest', plist)
            self.assertIn('audio', plist['UIBackgroundModes'])
            self.assertIn('fetch', plist['UIBackgroundModes'])
            self.assertEqual(plist['UIBackgroundModes'].count('audio'), 1)
            self.assertEqual(len([u for u in plist['CFBundleURLTypes'] if 'marcomovie' in u.get('CFBundleURLSchemes', [])]), 1)
            for svc in ('_marcomovie-cast._tcp', '_airplay._tcp', '_lelink._tcp', '_googlecast._tcp', '_dlna._tcp', '_upnp._tcp'):
                self.assertIn(svc, plist['NSBonjourServices'])
            app_fw_plist = plistlib.loads((flutter_ios / 'AppFrameworkInfo.plist').read_bytes())
            self.assertEqual(app_fw_plist['MinimumOSVersion'], '15.0')
            self.assertIn('IPHONEOS_DEPLOYMENT_TARGET = 15.0', (flutter_ios / 'Release.xcconfig').read_text(encoding='utf-8'))
            self.assertIn('IPHONEOS_DEPLOYMENT_TARGET = 15.0;', (xcodeproj / 'project.pbxproj').read_text(encoding='utf-8'))

    def test_ios_uiscene_implicit_engine_template_for_iphone_duo_idempotently(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            runner = root / 'ios/Runner'
            runner.mkdir(parents=True)
            (runner / 'Info.plist').write_bytes(plistlib.dumps({'MinimumOSVersion': '15.0'}))
            (runner / 'SceneDelegate.swift').write_text(
                'import Flutter\nimport UIKit\n\nclass SceneDelegate: FlutterSceneDelegate {}\n',
                encoding='utf-8',
            )
            app_delegate = runner / 'AppDelegate.swift'
            app_delegate.write_text(
                'import Flutter\n'
                'import UIKit\n\n'
                '@main\n'
                '@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {\n'
                '  override func application(\n'
                '    _ application: UIApplication,\n'
                '    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?\n'
                '  ) -> Bool {\n'
                '    return super.application(application, didFinishLaunchingWithOptions: launchOptions)\n'
                '  }\n\n'
                '  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {\n'
                '    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)\n'
                '  }\n'
                '}\n',
                encoding='utf-8',
            )
            with patch.object(prepare_platform, 'ROOT', root):
                prepare_platform.main()
                prepare_platform.main()
            swift = app_delegate.read_text(encoding='utf-8')
            self.assertEqual(swift.count('MarcoNativeChannelRegistrar.register('), 1)
            self.assertIn('engineBridge.applicationRegistrar.messenger()', swift)
            self.assertEqual(swift.count('marco_movie/wakelock'), 1)
            self.assertEqual(swift.count('marco_movie/system_chrome'), 1)
            self.assertEqual(swift.count('marco_movie/netdisk_auth'), 1)
            self.assertEqual(swift.count('"marco_movie/web_sniffer"'), 1)
            self.assertEqual(swift.count('"marco_movie/webview_js"'), 1)
            self.assertEqual(swift.count('"marco_movie/ios_avplayer"'), 1)
            self.assertEqual(swift.count('MarcoLiquidGlassPlugin'), 1)
            self.assertEqual(swift.count('MarcoAvPlayerPlugin'), 1)
            self.assertIn('override func viewWillTransition(', swift)
            self.assertIn('override func viewSafeAreaInsetsDidChange()', swift)
            self.assertNotIn('UIScreen.main.bounds', swift)
            self.assertEqual(swift.count('{'), swift.count('}'))
            plist = plistlib.loads((runner / 'Info.plist').read_bytes())
            self.assertIs(plist['UIRequiresFullScreen'], False)
            self.assertEqual(plist['UILaunchStoryboardName'], 'LaunchScreen')
            scene_cfgs = plist['UIApplicationSceneManifest']['UISceneConfigurations']['UIWindowSceneSessionRoleApplication']
            self.assertEqual(scene_cfgs[0]['UISceneDelegateClassName'], '$(PRODUCT_MODULE_NAME).SceneDelegate')
            self.assertIn('UIInterfaceOrientationLandscapeLeft', plist['UISupportedInterfaceOrientations'])
            self.assertIn('UIInterfaceOrientationPortraitUpsideDown', plist['UISupportedInterfaceOrientations~ipad'])

    def test_trollstore_entitlements_include_multicast_for_dlna(self):
        import patch_ios_ipa
        src = Path(patch_ios_ipa.__file__).read_text(encoding='utf-8')
        self.assertIn('"com.apple.developer.networking.multicast": True', src)

    def test_macos_main_window_injects_wakelock_and_web_sniffer_idempotently(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            runner = root / 'macos/Runner'
            runner.mkdir(parents=True)
            window_swift = runner / 'MainFlutterWindow.swift'
            window_swift.write_text(
                'import Cocoa\n'
                'import FlutterMacOS\n\n'
                'class MainFlutterWindow: NSWindow {\n'
                '  override func awakeFromNib() {\n'
                '    let flutterViewController = FlutterViewController()\n'
                '    let windowFrame = self.frame\n'
                '    self.contentViewController = flutterViewController\n'
                '    self.setFrame(windowFrame, display: true)\n'
                '    RegisterGeneratedPlugins(registry: flutterViewController)\n'
                '    super.awakeFromNib()\n'
                '  }\n'
                '}\n',
                encoding='utf-8',
            )
            with patch.object(prepare_platform, 'ROOT', root):
                prepare_platform.main()
                prepare_platform.main()
            swift = window_swift.read_text(encoding='utf-8')
            self.assertEqual(swift.count('import WebKit'), 1)
            self.assertEqual(swift.count('marco_movie/wakelock'), 1)
            self.assertEqual(swift.count('marco_movie/web_sniffer'), 1)
            self.assertEqual(swift.count('private final class HeadlessMediaWebSniffer'), 1)
            self.assertEqual(swift.count('{'), swift.count('}'))


if __name__ == '__main__':
    unittest.main()
