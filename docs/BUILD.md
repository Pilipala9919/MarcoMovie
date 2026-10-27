# 构建与检查

当前脚本在 Windows 上验证，需 Python 3、JDK 17、Android SDK Build Tools（建议 35.0.0）。脚本不依赖作者电脑的目录，也不需要影视配置。

## 构建 APK

在 PowerShell 中设置你自己的工具目录：

```powershell
$env:MARCOMOVIE_JDK = 'C:\Tools\jdk-17'
$env:MARCOMOVIE_BUILD_TOOLS = 'C:\Android\Sdk\build-tools\35.0.0'
python -X utf8 scripts/build_android.py
```

如果已有 `JAVA_HOME`，可省略 `MARCOMOVIE_JDK`。编译库默认由 `scripts/prepare_android_platform.py` 从 Android 官方地址下载 Android 35 平台包（核对归档 SHA-1 与提取的 android.jar 的 SHA-256）；也可用 `MARCOMOVIE_ANDROID_JAR` 指定自己的 `android.jar`。SDK 工具与平台的许可由其提供方规定。

依赖来自四个 JSON 清单，每项固定版本与 SHA-256。首次构建需要联网获取软件依赖，缓存位于 `tools/`。构建生成资源、Java 字节码、DEX 和 ARM 32 位原生库，再对齐、签名和校验。

输出：`dist/MarcoMovie-0.3.3-preview.apk` 及 `.sha256`；构建记录在 `android/build/build-validation.json`。生成记录中的“设备测试”字段不会因编译成功而自动改为通过。

## 签名

默认在 `android/private/development.p12` 生成本地开发密钥，开发口令为 `android`，不适合作为共享生产密钥。密钥文件被 Git 忽略。`MARCOMOVIE_SIGNING_KEY` 可指定本地已有的同格式密钥；当前脚本按开发签名流程使用，正式发行签名流程需自行配置。不要把密钥、口令或账号令牌提交到仓库。

## 本地功能检查

先运行基础检查，它会准备并校验 JVM 测试用 JSON 库，再运行其他检查：

```powershell
python -X utf8 android/tests/run_checks.py
python -X utf8 android/tests/run_live_checks.py
python -X utf8 android/tests/run_global_search_checks.py
python -X utf8 android/tests/run_compat_checks.py
```

这些检查使用保留的 `.test` 域名和本地 HTTP 模拟响应，不访问影视资源。构建 APK 后，还可运行 `android/tests/run_js_player_checks.py` 检查脚本播放路由的适配逻辑。路由检查不代表加载任意第三方脚本都成功。

发布前运行 `python scripts/check_public_content.py`。它检查公开文件范围、明显的凭据格式、个人目录、非允许的网络域名和资源二进制，不代替人工检查。只有 `git ls-files` 列出的文件会被提交；`private/`、`tools/`、构建结果和未脱敏的测试资料不得上传。

为同一应用发布升级包时，设置 `MARCOMOVIE_SIGNING_KEY` 指向已妥善保管的原项目签名文件；不要每次换用新签名。默认仍使用本地开发签名。签名文件不得提交到仓库。

## 真机验收

公开仓库不提供含实际账号和内容地址的真机探针。请使用你拥有授权的测试内容，在目标设备上核对遥控操作、分辨率、实际画面与播放时钟推进。URL 解析成功、准备完成回调或编译通过均不能单独视为真实播放通过。

原生解码组件构建、对应源码与许可见 [DECODERS.md](DECODERS.md)。合成媒体测试生成器 `android/tests/generate_decoder_fixtures.py` 需要本地 FFmpeg；`android/tests/device/DecoderProbe.java` 仅用于同签名仪器测试包，不随产品 APK 运行。

## 合成媒体与遥控器测试

`python android/tests/generate_decoder_fixtures.py decoder-fixtures` 生成 20 项样本/模式组合（需 FFmpeg），不使用影视资源。先构建主 APK，再用相同密钥运行 `python scripts/build_device_probe.py DecoderProbe` 或 `InteractionProbe` 构建独立测试包。测试包不是用户安装包。

在开发机用 `python -m http.server 18765 --bind 127.0.0.1 --directory decoder-fixtures` 提供样本，通过已授权测试设备的 `adb reverse tcp:18765 tcp:18765` 转发，安装主包与测试包后运行：

```sh
adb shell am instrument -w -e base http://127.0.0.1:18765/ com.pilipala.marcomovie.test/com.pilipala.marcomovie.DecoderProbe
adb shell am instrument -w -e base http://127.0.0.1:18765/ com.pilipala.marcomovie.test/com.pilipala.marcomovie.InteractionProbe
```

后者会临时替换收藏测试内容，并在 finally 恢复原收藏；仅在专用测试设备上运行。不要中断恢复过程。测试后关闭测试应用并移除 adb reverse。`run_decoder_checks.py` 和 `run_favorites_checks.py` 分别检查错误分类和收藏持久化；收藏检查先准备基础检查使用的 JSON 依赖。
