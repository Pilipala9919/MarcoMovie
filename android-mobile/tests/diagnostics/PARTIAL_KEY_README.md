# 分批渲染期间的原生按键实验（F → A → 云端）

本测试仅在授权云电脑的专用空 API23 TV AVD 运行。禁止操作用户电视、在用户电脑创建模拟器、清除用户数据、覆盖正式包或发布。本地仅准备源码、javac/D8静态编译；JVM行为断言和原生实验也交云端执行。

本补丁新增独立入口，不改变 HomeProbe / HomeRenderDiagnostics / GridRenderCompareProbe。三者与父提交6528b1ae6015a459c259cc982d10fe1070ee31bb的LF字节相同。此前12秒首窗失败保留；没有延长旧等待、减少500×4+1或2001条目要求。对照结果不授予S1或发布通过。

## 场景和断言

`PartialRenderKeyProbe`独立于原入口，复制已用过的ContextWrapper命名空间隔离方式；不修改产品。fixture使用真实Cms/SourceEngine解析路径，五页500/500/500/500/1，ID section-页码-页内序号。只有测试引擎产生合成数据和预置300×450海报；不是网络来源、冷缓存或正式实现。category与layout选择是明确的测试bootstrap（performClick/requestFocus）；进入首卡及之后的测试导航只经UiAutomation.injectInputEvent送DPAD down/up，不直接调用Activity.dispatchKeyEvent，不定焦末卡、不修改busy、State.videos、窗口或渲染队列。

Window.Callback代理在实际dispatchKeyEvent之前/之后记录状态，并且每次只反射调用原callback一次，返回值/异常原样传播。不消费按键、不主动追加卡片、不取消/重排产品任务。观测会有分配/计时成本；这不是未插桩发布性能。key的before/after在真正的窗口回调中读取，避免“发键前采样仍partial，但实际收键时已完成”被误记为命中。

记录焦点tag/绝对index/内容ID/attach/shown/屏幕相交矩形、nextDown目标，grid epoch、generation、window、page/items、已建cards/rows、pending/busy/ready、请求数和计时。实际收到1次DOWN及1次UP、keyCode/downTime匹配才有效。只在返回结果后截图（partial-key-result-native.png），不以截图延迟干扰关键发键前置。截图时间晚于失败状态/sidecar保存，必须分别解释。

两个场景：

| scenario | 做什么 | 通过仅代表什么 |
|---|---|---|
| edge | 从首卡开始向下，最多32次逻辑行推进，必须实际命中partial_tail_self或partial_focus_prefetch_boundary；记录即时及后续焦点 | 此次合成路径命中部分渲染边界、未看到跳窗/跳行或持续失焦。没有2001覆盖、没有性能/验收结论 |
| walk | 首列连续DOWN到index2000；检查五页2001唯一有序ID、请求页恰为1..5各一次；尾部DOWN；UP到earlier并OK逐窗返回0；OK进真实详情路径、BACK回原Home/焦点0且无分类重请求 | 此次合成输入遍历通过。仍不能代替原完整HomeProbe、真实源、物理遥控、弱电视、原型视觉、升级、IME/播放红线 |

DOWN的判定针对内容连续性：尚未到**逻辑窗口最后一行**时不得提前换窗；合法换窗仍不得跳过下一行；数据不得缩水，DOWN不得倒退焦点/窗口。5列首列正常轨迹为0→5→…→2000；不会把“窗口前进了”自动视为成功。部分渲染暂时没有下行时允许焦点原地保留并重发实际DOWN，但同一逻辑行共用原12秒guard，不因重试重置deadline。12秒后仍无进展/焦点不可用分别报ROW_PROGRESS_TIMEOUT/FOCUS_LOST_TIMEOUT。

全实验420秒软预算、最多2400对键；云端runner硬上限600秒。任何同步注入/主线程等待失去响应由host硬超时收集logcat和进程状态，不当作business pass。edge未命中边界须报未覆盖，diagnostic_quality.valid=false，不能在较快设备上“没遇到就通过”。native input/callback缺失或sidecar错误也属于诊断无效。事件中暂时focus不可用不直接等于持久缺陷，需结合guard结果；合法换窗的布局期间允许短暂空焦点。

新增风险的两条来源都要观察：HomeScreen.wireNavigation把已建末行DOWN指向自身→navigationKey→maybeAutoLoadMore；以及card.onFocusChange用当前rows.size判断near-end→maybeAutoLoadMore。前者可能在末行自指时出现，后者可能在普通DOWN刚进入第二行时发生。旧基线也有对应链，故不能预设V17新回归。实验在首次确认内容跳跃时保留原失败并停止该实例；不能为了到2001而跳过断言。

## 构建与包需求（A接入，不由F发布）

1. 产品仍固定current=f194405e5890aef922b9a11af8be9558fedc9d75，baseline=55799fd3c829075547c26b1e76e0de95cc833e5c。分别使用各自真实完整应用classpath编译新测试，不混用新版业务类做旧基线。
2. 新最小probe需要`PartialRenderKeyProbe.java`和`PartialKeyContract.java`及所有生成的内部/匿名类；manifest新增instrumentation `com.pilipala.marcomovie.PartialRenderKeyProbe`，targetPackage仍com.pilipala.marcomovie。这两个类无HomeRenderDiagnostics/旧GridRenderCompareProbe运行依赖。旧入口及其原包/结果全部保留。
3. 本次不改HomeScreen观察覆盖层。若重用上一轮诊断fixture，current SHA=69c8b3a2a6c1006f94935154cc481fa06a30c7faad30f3d426dfa3fa60a3727e，baseline SHA=8b80f95dc1d6bd83f99b578945cf62567aaebe399c3130107fbb95ce5246d0f0。它们的HomeGridTrace本实验不调用begin，保持未启用；不能描述为无插桩正式包。A若重建了fixture必须给出新哈希/来源，不能沿用旧身份。
4. 两个新probe必须各自重新签名/计算哈希，使用与fixture相同的开发证书，记录F提交/A接入/产品SHA、APK/DEX/资源与证书哈希、0.5.25/87和API23/ABI范围。包名版本不代表正式发布或与已装正式版可覆盖。禁止导入用户账号、配置、缓存、ADB私钥和签名私钥到分发证据。
5. runner新增显式partial入口/参数白名单；不复用旧render_waits分析器强行判通过。`cloud_run=true`只是测试参数，app另拒绝非API23/x86/ranchu/1920×1080/density320，不能证明宿主是云端；host runner必须核实云主机身份、实例是新建专用空AVD、精确包对及安装后拉回哈希。没有自动安装/清理用户设备的代码。
6. 原生调用参数需完整传入：isolated_target=true、cloud_run=true、scenario=edge或walk、layout=right或left、精确product_revision、唯一run_id。baseline仅允许right；left仅current。run_id和product_revision参数须由runner的签名/哈希绑定验证，不能仅信任app回显。
7. 先拉namespace内所有JSON/PNG，再判断passed。必须保留result、完整instrumentation输出、完整logcat、partial-key-events.json、截图、capture_error、安装后包哈希、设备/显示属性、UTC起止、AVD创建和启动配置、宿主CPU/RAM/GPU/加速模式/负载、runner日志。失败时也要提供原始字节SHA，并将sidecar/文本/PNG单独保存；直接附原图或提供可读取原PNG，不以OCR替代像素。
8. 运行`analyze_partial_key_events.py result.json partial-key-events.json`得到独立结构/输入配对/内容跳跃分析。它永远输出acceptance_passed=false。runner要分别保留业务结果、诊断有效性和原HomeProbe失败状态；非零/超时不可改成skip/pass。不要把“有效捕获缺陷”写成“功能通过”。

## 固定有限云端计划

机器可读顺序见`partial_key_cloud_plan.json`，**最多10次，每项只运行一次，彼此新空AVD**：right edge三对，顺序B-C / C-B / B-C；right walk一对C-B；current left edge和walk各一次。每次沿用相同API23镜像指纹、原生1920×1080/density320、CPU/RAM/GPU、加速、启动参数及空实例策略，记录实际宿主负载。全部预置同一合成海报，不把“空AVD”误写成“海报冷缓存”。共同right配对才能横向比较；left没有旧版同UI对照，walk与edge也不能混合比较速度。

预先声明的业务失败保留并继续后续独立实例；出现环境/包身份/观察链无效则暂停批次修复该基础问题，不反复重跑直到成功，不自动加量。三对只用于复现一致性和波动观察，不足以建立统计等价/无回归结论。walk失败即2001仍未完成；不得缩为40项或删除连续性断言。原HomeProbe的12秒失败不覆盖、不重标，不在本批自动重跑。

本文件是交接计划，不会启动云任务。云端执行由总协调安排。所有物理设备、真实来源、#52冷缓存遥控、#55厂商HTTPS、背景播放器/Surface/暂停、系统IME、升级和隐私仍单独验收；S1_READY继续为否。

## 静态准备和云端oracle

`check_partial_key_probe.py`默认只验证旧源码未改、用current/baseline各自classes分别javac与D8 min-api23，以及编译oracle；不执行测试、不建APK、不签名、不调用ADB。

参数：`--out`为本副本android/build下全新目录；`--jdk --android --d8 --current-classes --baseline-classes`均为明确路径。云电脑上如需执行纯JVM oracle，额外设置MARCO_AUTHORIZED_CLOUD_TEST=1并使用`--cloud-contract`；Windows拒绝该执行模式。`PartialKeyContractCheck.java`包含17个命名检查（其中一个检查400次连续合法跨窗步进）；它只验证判定合同，不证明原生事件链。

本轮初次静态编译因误继承final旧probe失败，日志保留；改为独立Instrumentation类后重新检查。失败未靠修改旧类/final关键字或删功能断言解决。最末静态检查记录见F交付收据；JVM/native运行结果必须等云端返回后单独记录。
