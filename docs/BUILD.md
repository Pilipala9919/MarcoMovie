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

依赖来自三个 JSON 清单，每项固定版本与 SHA-256。首次构建需要联网获取软件依赖，缓存位于 `tools/`。构建生成资源、Java 字节码、DEX 和 ARM 32 位原生库，再对齐、签名和校验。

输出：`dist/MarcoMovie-0.3.2-preview.apk` 及 `.sha256`；构建记录在 `android/build/build-validation.json`。生成记录中的“设备测试”字段不会因编译成功而自动改为通过。

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
