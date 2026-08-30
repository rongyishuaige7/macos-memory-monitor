# v1.0.6d 详情布局边界与可访问性收敛

## 范围

本阶段继续收敛进程详情和工作组详情的自适应布局契约：

- 让横向/纵向布局的宽度判定与实际子视图放置使用同一精确边界，避免理论上的半像素溢出；
- 让关系行（父进程链）使用可测量的标签、名称和尾部值，而不是依赖固定标签宽度的独立 `ViewThatFits` 候选；
- 让指标数值在 Dynamic Type 下随系统文本样式增长，并保护极窄正文提案不产生不可访问的横向内容；
- 用纯值契约和 `NSHostingView` smoke fixture 锁定上述行为。

## 非目标

- 不改变采样、历史记录、工作组归因、进程操作权限或确认流程；
- 不调整详情 sheet 的最小/理想窗口尺寸、导航路由或信息架构；
- 不引入第三方布局、快照或 UI 测试依赖；
- 不向正式实例、c3c 实例或任何真实进程发送信号；
- 不修改用户已有的 `ScratchProbe.swift` 和 `ScratchProbe 2.swift`。

## 架构

`DetailLayoutPolicy` 继续是所有阈值的唯一来源。布局层只负责测量和放置：

1. `modeForRequiredWidth` 使用精确的 `available >= required` 判定；布局在放置时把计算出的子视图宽度和起点限制在 bounds 内。
2. 新的关系行测量布局读取每个子视图的 ideal size，按同一策略决定 inline 或 stacked；关系行的生产视图和契约测试都调用同一纯函数。
3. 指标 tile 的主要数值采用动态系统文本样式，保留有限的视觉上限；正文宽度解析对非正/非有限 viewport 做保守处理，并在极窄提案下优先纵向布局。
4. smoke fixture 继续使用固定字符串和 `NSHostingView`，覆盖默认字号、`accessibility3`、边界宽度和极窄宽度；不把单机 AX 树结果冒充为 CI 自动化证明。

## 风险

- SwiftUI `Layout` 的 ideal size 和 `ViewThatFits` 测量会随 macOS 字体和版本变化；契约测试只锁定决策，不锁定像素；
- 去掉容差可能让刚好不足一个小数点单位的窗口更早切换为 stacked，详情高度会增加但信息可读性更高；
- 关系行从固定标签宽度改为测量宽度后，中文标签和大字号下的换行点会变化；
- Dynamic Type 的系统文本样式可能改变指标网格行高，必须确认滚动容器仍能到达底部；
- 极窄 viewport 仍可能由宿主窗口或系统滚动条产生额外裁剪，生产 sheet 的最小宽度只提供当前平台的保护。

## 验收标准

- `modeForRequiredWidth` 在 `required - 0.01`、`required` 和 `required + 0.01` 上给出可解释且无溢出的结果；
- 关系行契约覆盖短标签、长标签、长名称、长尾部值和 `NaN`/无限提案，生产布局不再保留固定 `52pt` 标签依赖；
- 指标 tile 在 `.accessibility3` 下测量高度有限且不低于默认字号，数值不使用固定字号压缩到不可读大小；
- 极窄 fixture 的测量宽度保持在提案范围内且详情内容仍有正高度；真实子视图 frame 由独立桌面检查复核；
- `swift test --package-path . --parallel`、严格并发 Debug/Release 构建和 `./scripts/verify-release.sh` 通过；
- 每个实现/文档切片单独提交并推送到 `origin/main`，两个 `ScratchProbe` 文件始终未跟踪。

## 分阶段交付

1. **边界契约**：去除半像素容差、增加放置范围和极窄宽度测试。
2. **关系行统一测量**：抽取专用 Layout，接入父进程行并补充 smoke 覆盖。
3. **Dynamic Type 与指标可读性**：改用动态文本样式，验证大字号和滚动高度。
4. **验证交付**：运行全量门禁，更新本记录，分批提交并推送。

## 实施结果

- `modeForRequiredWidth` 已改为严格的 `availableWidth >= requiredWidth`，并由 `boundedInlineWidth` 约束 inline 分支的子视图宽度和放置起点；边界不足时会回退为 stacked，不再依赖 `0.5pt` 容差。
- 父进程关系行已接入 `AdaptiveDetailRelationRowLayout`。标签、名称和尾部值先取 ideal size，再由 `DetailRelationMetrics` 统一计算三个间距和 spacer 的实际需求宽度；生产布局和契约测试不再依赖固定 `52pt` 标签宽度。
- 有限 viewport 现在优先决定正文宽度，窄于生产最小窗口时同步收缩正文和水平内边距，避免垂直 `ScrollView` 产生无法到达的横向内容。
- 指标 tile 的主数值改用语义 `.body.weight(.semibold).monospaced()` 字体，并把单行压缩下限从 `0.65` 提升到 `0.75`；标题和说明仍保持现有的信息层级。
- 纯值契约覆盖精确边界、测量关系行、异常浮点输入和放置范围；`NSHostingView` smoke 覆盖默认字号、`accessibility3`、长值、窄关系行、三按钮回退和指标一列回退。

## 验证记录

验证日期：2026-08-31，平台为 macOS `26.5.1`、Apple Silicon `arm64`。

- `git diff --check` 与暂存区检查：通过。
- `swift test --package-path . --filter DetailLayoutContractTests --parallel`：退出码 `0`，6 个契约用例完成。
- `swift test --package-path . --filter DetailLayoutSmokeTests --parallel`：退出码 `0`，5 个 smoke 用例完成。
- `swift test --package-path . --parallel`：`252/252` 通过。
- `swift build --package-path . --configuration debug -Xswiftc -strict-concurrency=complete`：通过。
- `swift build --package-path . --configuration release -Xswiftc -strict-concurrency=complete`：通过。
- `./scripts/verify-release.sh`：通过；包含全量测试、严格并发 Debug/Release 构建、Release probe、结构化兼容性报告、默认 arm64 App bundle 和 `codesign --verify --deep --strict`。本轮 probe 读取 `335/544` 个进程（部分可用），报告为 schema `1`、macOS `26.5.1`、arm64，App 版本 `1.0.3`、build `13`。

AppKit headless fitting 不会在所有系统配置下稳定应用 Dynamic Type 的字号缩放，因此指标 smoke 只断言大字号测量结果有限且不低于默认字号；它不宣称高度必然增加，也不替代登录桌面上的 AX 检查。

## 独立桌面检查边界

本批使用最新 Release bundle 做了隔离的面板级 AX 检查：

- bundle 位于临时目录 `/tmp/memory-monitor-ui-check-v106d-20260831-000139/app-output/MemoryMonitor.app`，临时标识为 `com.rongyi.MemoryMonitorUICheck.v106d`；通过 `CFFIXED_USER_HOME` 把 Foundation 的 Application Support 重定向到同一临时目录。
- 面板成功打开，AX 窗口约 `410x605pt`，树中有 56 个元素；可见 `全量进程观察 · 已采集 386/609 个进程`、CPU/内存/GPU 值、`进程数据部分可用`、搜索字段、筛选与排序、进程/工作组切换、滚动区和退出入口。面板检查没有点击任何进程操作或信号按钮。
- 临时进程已结束；正式 `~/Library/Application Support/MemoryMonitor`、正式实例、c3c 实例及其 evidence 目录未触碰。临时历史只写入 `/tmp` 隔离 home。

本批没有取得新的真实进程详情/工作组详情滚动末端截图或完整 AX 树结果：详情行的自动定位在本次时限内未稳定完成，因此不把面板证据扩大解释为详情证据。详情关闭入口、滚动末端和关系/指标区域的真实 AX 基线继续沿用 [`detail-layout-v1.0.6b.md`](detail-layout-v1.0.6b.md)；本批新增布局行为由纯值契约和 `NSHostingView` smoke 覆盖。下一批应保留临时数据目录隔离，并补完两种详情页的只读 AX 检查。

## 提交记录

- 源码与测试批次：`20bf6be`、`5846a85`、`1a89e3e`、`72c11d5`，均已推送至 `origin/main`。
- 本文档为独立验证交付批次；提交后应确认只有本文档进入提交，两个 `ScratchProbe` 文件继续保持未跟踪。
