# HomeProbe 窗口渲染诊断（F → A）

仅供独立测试包。正式产品源码、功能断言、500项单页限制、五页2001目标、按键次数和12秒等待均不修改。此目录不安装设备、不签名、不发布，也不启动任何服务器。

## 交付组成

- `../device/HomeProbe.java`：只将末卡存在等待接入观察器。其余源码与F父提交 `a088e7818ad86eff04b6b3dd69456975ff2ca1e7` 按LF逐字节相同。
- `../device/HomeRenderDiagnostics.java`：同样的12秒deadline、80ms sleep、原predicate和超时AssertionError。只在原有UI轮询中稀疏采样（通常250ms，最多64次）；记录卡片/行数、epoch、pending任务身份、active/ticket/generation、content附着/显示、窗口、UI排队和条件查询耗时。不会调用加载、补发按键、设置焦点或直接追加卡片。
- `HomeGridTrace.java.in` + `prepare_home_render_diagnostics.py`：从两个精确Git产品提交生成**编译目录中的**HomeScreen诊断副本及观察器。捕获真正的续批、帧回调到达、handler投递结果/到达、取消和epoch拒绝；分段记录构建、导航连线、焦点处理和批次耗时。产品仓库文件不被改写。
- `../device/GridRenderCompareProbe.java`：独立的共有右导航网格对照，基线/当前都使用相同源、500项、五列、360窗、合成缓存图片和12秒等待。只比较首窗构建；不调用DOWN，不声明累计2001或左分区通过，不能替代完整HomeProbe。
- `check_home_render_diagnostics.py`：离线逆变换/编译/D8和诊断合同检查，无APK/设备操作。
- `analyze_home_render_trace.py`：只读分析sidecar中的增长、分段耗时、队列间隔、取消/拒绝、缺失端点与记录损失。不会自动将某个耗时定为缺陷或通过。

## 来源与输出约束

只接受以下两个产品源：

| 身份 | SHA |
|---|---|
| S0基线 | `55799fd3c829075547c26b1e76e0de95cc833e5c` |
| 当前产品 | `f194405e5890aef922b9a11af8be9558fedc9d75` |

在接入此测试提交的工作副本执行，例如：

```powershell
python android/tests/diagnostics/prepare_home_render_diagnostics.py --revision f194405e5890aef922b9a11af8be9558fedc9d75 --out android/build/render-diag-current
python android/tests/diagnostics/prepare_home_render_diagnostics.py --revision 55799fd3c829075547c26b1e76e0de95cc833e5c --out android/build/render-diag-base
```

输出必须是当前工作副本 `android/build` 下尚不存在的子目录。工具不覆盖既有输出；不从可变产品工作树取源。每项插桩有精确before/after及逆向检查，去掉观察插桩后必须与指定Git源码完全一致。`overlay-receipt.json`记录来源/生成文件SHA。它证明插桩位置和业务语句保持，不证明观察器没有时序开销。

`a.ui.post(nextBatch)`仍只调用一次，原active/epoch判定、批次数/预算和分帧方式不变；只额外记录其返回值。未增加frame callback、重试或替代调度。跟踪在第一次末卡轮询启用，原第一批可能早于它，故不能冒认整次分类首次渲染总耗时。

## A的构建要求

1. 先审查生成副本和逆变换收据。正式`android/src/main`与原产品classes.jar保持不变。构建一份**单独命名的诊断fixture**：在副本classes中替换整组`HomeScreen.class`及其`HomeScreen$*.class`，加入`HomeGridTrace.class`，再对完整应用类集合重新D8；不要把新DEX简单叠到旧APK，造成同名类重复或残留旧匿名类。
2. 当前fixture来源必须仍是f194405的完整应用/资源/原生依赖；基线fixture必须从55799fd的完整应用重新构建。**不得用当前版其他类混成“旧基线”**。F的基线HomeScreen语法编译使用当前依赖classpath，仅是编译检查，不是已构建可运行的旧基线。若A暂不能得到真实基线fixture，保留此限制，可先交当前版诊断，不能声称完成对照。
3. 当前完整版probe编译列表增加`HomeRenderDiagnostics.java`，其余原probe入口保持。共有对照probe编译`GridRenderCompareProbe.java`和`HomeRenderDiagnostics.java`；在manifest注册`com.pilipala.marcomovie.GridRenderCompareProbe`，targetPackage保持`com.pilipala.marcomovie`。基线probe仅打包共有对照入口，避免将V17专有字段引用的HomeProbe混入基线。
4. fixture和probe均使用原开发证书，记录新APK/DEX/classes/资源SHA及签名；原产品版本不变，不能拿版本号识别包。此时**fixture SHA也改变**，不能继续使用第三轮fixture常量。runner为每组允许精确fixture/probe对，运行前拉取已装APK实测校验；原三轮APK、证据、失败状态保留。
5. runner继续仅面向已授权的新空云端API23/x86/Leanback目标，保留空数据隔离、显示参数和600秒host总限时，不安装用户电视、不清数据、不通过放宽等待重试。A负责打包交接，实际云端执行由总协调安排。
6. `render_waits[]`只含小型索引。真正事件数组位于同一`home_probe_v17_*`隔离目录的`home-render-wait-NNN.json`。runner必须在passed判定前拉取整个本轮目录，保留**所有JSON和PNG**，不能只上传图片。完整HomeProbe失败后原现场截图仍保留；记录sidecar序列化/停止跟踪在超时之后，截图时间可能晚于最后一个采样。
7. 使用诊断fixture的本轮交付要检查每个等待的`trace_available=true`、fixture_source符合收据、无`render_diagnostic_error`、事件/样本结构有效。缺失观察器不能被当作完整诊断证据；该质量状态与原业务passed分开记录。事件overflow/trace_errors/不配对端点必须保留并解释，不能静默丢弃。

原Library ZIP不增加用户数据、密钥库、ADB密钥、SDK或系统镜像。测试源码/合成源只存在测试包；诊断fixture不能作为正式候选发布。正式手机共享代码不改；诊断副本中的HomeScreen观察插桩不代表手机路径已验证。

## 云端三组试验

| 组 | 应用 | probe | 用途 |
|---|---|---|---|
| V17完整链 | 当前诊断fixture | HomeProbe | 保留原全部断言和五页2001；定位真实失败窗口 |
| 当前共有网格 | 当前诊断fixture，新空目标 | GridRenderCompareProbe | 共有右布局首窗构建观测 |
| 基线共有网格 | 基线诊断fixture，新空目标 | 同一GridRenderCompareProbe源码 | 与上组同条件比较 |

共有两组使用相同API23镜像指纹、x86、1920×1080/density320、模拟器硬件/渲染配置、进程启动方式和显示/字体参数。记录宿主配置、加速状态和并发负载，不将其直接当作失败原因。不要串行覆盖同一个既有安装；由总协调按已授权范围准备相互独立空目标。旧基线没有V17左分区，故它只能比较共有网格；当前右布局与完整链的热身历史不同，也不能直接混算耗时。

每组都保留：准确源/测试提交、安装后APK哈希、设备属性、UTC起止、result/完整HomeProbe或Compare日志、完整logcat、本轮全部sidecar及原生PNG。首次取证每组一次即可，不自行循环重跑。单次结果不能给出稳定性能分布或物理电视结论。

## 指标边界

事件以`home_id + captured_epoch + start`关联，取消事件允许epoch递增；owner变化可从样本看到，观察器不自动接管新owner。窗口截止后停止记录事件/状态；`events_after_deadline`只计已忽略的观察调用。停止和文件序列化发生在wait结果之后，不会将false改true或延长predicate等待。

5ms/12ms原循环预算不包含导航/布局绘制；`build`是循环区间，`wire`是连线调用区间，`focus_or_finalize`的末批value=1还含原`updateMore`。`animation_queue`包含到下一次相关帧回调的等待，`handler_queue`是投递后到续批到达，不是GPU耗时或真实整帧时长。记录`trace_mark_ns`、`trace_begin_ns`、`observer_ns`、predicate查询耗时，观察开销不能忽略或直接从端到端时间机械相减。

若记录持续增长，结合构建/连线/队列区间查瓶颈；若长时间不增长，查attached/active/ticket/epoch及取消/拒绝/投递失败。缺失端点也可能是跨越12秒采集边界，不能直接报调度丢失。观察版偶然通过不抹掉第三轮失败；任何正式修复仍需原完整行为矩阵复验。

```powershell
python android/tests/diagnostics/analyze_home_render_trace.py path/to/home-render-wait-000.json
```

本测试预置合成bitmap，是缓存图场景，不验证#52冷缓存下载、实体遥控、厂商API23、#55 HTTPS兼容、播放器背景/暂停/Surface、系统IME或升级迁移。S1_READY继续为否，直至各门槛有独立证据。
