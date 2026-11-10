# iOS 原源与网盘适配验证记录

本轮针对用户在 iOS 27.0、Marco Movie 0.5.14 的反馈：玩偶哥哥原应返回网盘文件，却显示其他采集线路。当前改动属于验证版本；源码测试、匿名目录访问、Mac 编译、iPhone 实播分别记录，互不替代。

## 根因

0.5.14 的兼容桥把原插件映射到内置 MacCMS 采集池，再按片名聚合其他来源的线路，却保留原站点名称。详情和播放器恢复还会继续补入跨站线路。另有扫码登录把一次性二维码票据直接当作账号会话保存，造成“已登录”假象。

## 实现范围

- 移除内置采集池、插件名到其他采集源的映射、跨来源自动混线。旧 WoGG 普通 HTTP 缓存不能再冒充原源播放；其他未适配插件明确失败。
- 新增纯 Dart WoGG 目录适配。首页、分类、筛选、搜索、详情使用原站路径；来源地址从用户导入的已审阅插件数据或明确的 `siteUrl` 读取，不内置影视站地址，不执行 Android JAR。
- 当前审阅插件整包 SHA256：`da3f3a7afcfcded4d58d9c3a574dfb5cb2ddcc3db4290b7d8b3a7346f9ee8096`。数据提取同时验证内层摘要；未知版本不会降级到其他资源。
- 原站分享块映射为对应网盘线路。文件名、目录、大小来自原网盘。部分失效分享有独立提示；全部失败时报告失败，不替换来源。
- UC、百度、阿里及夸克分别使用对应协议；剧集只保存稳定分享/文件引用，播放时重新取得临时令牌。原画仅标注原画，转码画质由服务响应决定。
- UC CAS 票据经官方 mobileinfo 交换账号 Cookie；百度二维码票据经官方 qrbdusslogin 交换 BDUSS/STOKEN；阿里必须解析真正 refresh token。旧占位凭据保留但不再显示为有效登录。
- 登录预检、脱敏错误原因、播放器切集/返回取消已贯通。账号切换会阻断旧会话继续操作。阿里与夸克在需要时仅转存到专用目录，不删除用户已有内容；阿里用来源标识与内容 hash/size 校验复用。
- 原分享目录递归和分页有请求、大小、层级上限；超限明确报错，不再静默只取第一页或少量子目录。

## 验证与限制

基线为 `5a801a4`；Windows 使用项目锁定 Flutter 3.38.9 / Dart 3.10.8。自动化测试均使用合成账号、分享和媒体响应，不包含用户凭据、真实分享链接或用户媒体。

- 当前订阅解码及原插件配置提取通过。实际插件与实际首页快照回放得到 8 个分类、120 个目录条目。
- 新增协议测试覆盖分页、原始文件一致性、临时令牌刷新、账号切换、请求取消、游客凭据隔离、来源归属、重复转存与不删除现有文件。
- `CmsClient` 集成测试覆盖原目录 → 原分享 → 稳定剧集引用 → 原画地址，以及过期分享提示、旧混线拒绝和筛选参数映射。
- 原详情五份分享匿名实查：三份夸克分别读到 13 / 6 / 13 个视频，两份百度匿名失败；用户账号读取次数为 0。百度会话重试和 UC 已登录大文件仍以合成协议验证为准。
- iOS 平台包、Python 打包、运行时选择、Guard 数据提取宿主测试已在 Windows 验证。
- 完整 Flutter 回归 **503 项通过**；受影响代码及新增集成测试静态分析 **0 error / 0 warning**，31 条风格/弃用 info。公开文件扫描、差异空白检查、src/lib 内容一致性通过。Windows 无 Xcode；Mac 编译结果单独记录。
- UC 游客受限时通过现有账号重试同一原文件。需要账号的媒体以短期本地 Range 通道播放，账号不进入播放器请求头；只允许已核对的 UC 自有域，拒绝未知域和重定向。分享仍受用户账号/会员及服务端权限限制。
- 首播等待媒体配置完成；锁定 iOS 媒体库已包含 MKV / HEVC / VideoToolbox，不据 GitHub 新版本盲目升级。v0.6.0 iOS GLES 高位深渲染存在上游 BGRA 转换，不能把可解码等同于完整 HDR / Dolby Vision 输出。
- 尚无本轮安装到用户 iPhone 的证据。会员权限、超大原文件、HEVC/HDR/杜比视界、真实尺寸、拖动、切集及重启后的授权状态仍须在测试包上实测。
- 本轮不修改正式下载通道，不发布正式版；已有 Android、Lite 及其他任务的工作区改动不纳入测试分支。

## GitHub 交叉核对

用户要求参考公开项目以提高效率。本轮核对协议事实与已使用播放器的上游，不直接复制许可证不兼容的实现：

- [media-kit](https://github.com/media-kit/media-kit)：项目现有 Flutter 播放依赖，上游说明 iOS 与 macOS 的 libmpv 渲染和硬件解码架构。
- [libmpv-darwin-build](https://github.com/media-kit/libmpv-darwin-build)：项目现有 iOS 设备/模拟器媒体框架的构建来源。
- [YunX UCApi.kt（2381a529）](https://github.com/CYQawa/YunX/blob/2381a52960cf6e49c998e79630df9cd97007130d/app/src/main/kotlin/com/yunx/app/data/network/UCApi.kt) 和 [UCConstants.kt](https://github.com/CYQawa/YunX/blob/2381a52960cf6e49c998e79630df9cd97007130d/app/src/main/kotlin/com/yunx/app/data/network/UCConstants.kt)：核对 UC 游客/已登录下载请求、同响应游客凭据和官方配置刷新。仓库 AGPL-3.0；本轮独立实现协议，不复制其代码。
- [MoonTVPlus baidu.client.ts（8a1137b）](https://github.com/mtvpls/MoonTVPlus/blob/8a1137b56cd0acc0ddf1f1cc7009e6f80a8efc24/src/lib/netdisk/baidu.client.ts)：核对百度 uid、DLNA 毫秒时间/SHA1签名及媒体 User-Agent。仓库 LICENSE 为 CC-BY-NC-SA-4.0；只作协议交叉证据。
- [uzVideo 百度实现（f399ceb）](https://github.com/YYDS678/uzVideo-extensions/blob/f399ceb74ba5ceb0010688d7a72e16f1cc4ddd9d/panTools/js/panTools2_sub/baidu.js)：独立核对相同百度协议；未见根许可证，不复制代码。

## iPhone 验收

安装验证包后先刷新原订阅和原影片详情。若旧版本保存的是未交换的一次性票据，按提示重新扫码，不需要向开发者发送账号、Cookie 或密码。分别检查原站线路名、完整目录/集数、同一原文件实际播放、原画/转码切换、拖动和自动下一集；再验证切号、后台返回与重启。记录实际视频宽高、编码和是否有声画；不能仅凭文件名带 4K 判断通过。
