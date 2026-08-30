# detail-layout-v1.0.6f：隔离详情 fixture

## 范围

本阶段为详情页补齐可重复的桌面验证数据，覆盖：

- 一个包含多个成员的工作组；
- 多条历史分钟记录和可由分析器推导的进入、离开、增长事件；
- 多条本地脱敏审计记录；
- 长工作组/进程标签在真实进程详情、工作组详情和辅助功能树中的表现；
- 详情页顶部、末端滚动位置和关闭入口。

fixture 只在显式 UI-check 环境变量下启用，并且所有持久化文件都写入启动器创建的临时目录。

## 非目标

- 不改变正常启动的采样器、默认存储路径、采样频率或进程操作策略；
- 不向真实进程发送优雅退出、强制结束或其他信号；
- 不把合成快照当作生产采样质量或性能证明；
- 不把本地桌面 AX 观察包装成 CI/XCUITest 覆盖；
- 不修改用户已有的 `ScratchProbe.swift` 和 `ScratchProbe 2.swift`。

## 架构

1. Core 提供 `MemoryMonitorUIFixture`，以公开 Codable 模型构造固定工作组、进程、历史记录和审计事件。当前快照使用稳定的合成 `ProcessIdentity`，时间戳在每次采样时对齐到请求时间。
2. `memory-monitor-fixture` 可执行工具通过 `HistoryStore` 和 `ProcessActionAuditStore` 写入指定临时根目录，沿用正式快照、journal、clock sidecar、锁和权限逻辑；不直接拼接生产 JSON。
3. App 仅在 `MEMORY_MONITOR_UI_CHECK_FIXTURE=1` 时选择合成 `MonitorSamplingSource`。默认 delegate 初始化保持 `MonitorSampler()` 不变。fixture 进程的可执行路径为空，进程操作策略因此明确拒绝，不产生信号控件。
4. `scripts/launch-ui-check.sh` 在启动 App 前调用 fixture 工具，验证历史/审计文件已经出现，再通过 Launch Services 传递隔离 `HOME`、`TMPDIR`、storage root 和 fixture 标志。
5. 无头测试继续使用 `NSHostingView` 检查长成员/审计行的有限宽高和合并 AX 标签；桌面证据只读取隔离 bundle 的 AX 树，不执行退出或进程操作。

## 风险

- 环境变量是进程级开关，必须只由显式 UI-check 启动器设置；任何缺失、空值或非 `1` 值都回到正式采样路径；
- fixture 写入器若绕过 store API，可能与 journal/clock 规则漂移，因此必须通过 actor store 写入并检查结果；
- synthetic 时间必须落在当前保留窗口和未来偏差范围内，启动延迟不能让记录被首次加载立即裁剪；
- 合成进程身份不对应内核对象，任何未来新增操作入口都必须继续由不可用路径或显式只读门禁阻断；
- SwiftUI/AX 文本和系统字体随 macOS 版本变化，桌面记录只陈述观察到的尺寸和标签，不承诺跨版本像素一致。

## 验收标准

- `swift test --package-path . --parallel` 及严格 Debug/Release 构建通过；
- fixture 工具只接受显式临时根目录并成功生成历史、journal/clock 与审计、clock 文件，文件权限保持 `0600`；
- 默认启动在未设置 fixture 标志时仍使用真实 `MonitorSampler`；
- 隔离 bundle 的工作组详情能读到至少两个成员，进程详情能读到长身份字段；
- 隔离 bundle 的历史事件区能读到多条记录，审计区能读到多条长标签事件；
- 进程和工作组详情从顶部滚动到末端后都能找到关闭入口，成员/审计行保持有限高度并有合并 AX 标签；
- 每个代码、脚本、文档切片单独提交并推送；正式实例/存储和两个 `ScratchProbe` 文件不受影响。

本轮状态：前 3 项、历史/审计 fixture 和安全边界已完成并有自动化或启动器证据；详情页 AX 条目在当前桌面会话中延期，原因和可复核边界见“最新 AX 证据”。

## 分阶段交付

1. **设计与边界**：记录 fixture 数据、开关、只读安全门禁和验证标准。
2. **数据工厂与写入器**：复用 Codable/store API 生成临时历史和审计数据，并增加值级测试。
3. **App fixture 采样模式**：显式开关下注入稳定多成员快照，增加默认路径回归测试。
4. **启动器与桌面证据**：预置数据、启动隔离 bundle，完成真实 AX 导航和文档记录。

## 实施结果

- Core 增加 `MemoryMonitorUIFixture` 数据工厂和 `memory-monitor-fixture` 写入器。数据工厂固定生成 7 个合成进程和 2 个至少包含 3 个成员的工作组；进程的 `executablePath` 为空，`ProcessActionPolicy` 会拒绝所有 fixture 目标，因而不会出现可执行的退出/结束信号路径。
- fixture 写入器通过正式的 `HistoryStore`、`ProcessActionAuditStore` actor API 写入并重新加载数据，而不是拼接生产 JSON。每次运行生成 240 条历史记录、239 条未压缩 journal 增量和 12 条审计事件；分析器可从历史窗口推导工作组进入、离开、增长及压力转换事件。
- 启动器只接受 `/tmp` 或 `TMPDIR` 下明确指定的空目录，使用 `umask 077`，将存储根目录设为 `0700`、7 个快照/journal/clock/lock 数据文件设为 `0600`，并在启动前校验文件存在、非空、数量和行数。JSON 内容由生产 store actor 回读校验，避免使用不适用于 JSON 的 plist 语法检查。
- App 只有在 `MEMORY_MONITOR_UI_CHECK_FIXTURE=1` 时才注入合成 sampler；缺失、空值或其他值仍创建生产 `MonitorSampler`。Launch Services 启动使用 `env -i` 最小环境，并校验子进程实际继承的 `HOME`、`CFFIXED_USER_HOME`、`TMPDIR`、隔离 storage root 和 fixture 开关。
- 启动器按完整可执行路径做字面匹配，并对 `pgrep` 正则元字符转义；包含 `[`、`+` 等特殊字符的临时路径已实测不会误匹配正式实例。

## 验证记录

验证日期：2026-08-31，平台为 macOS `26.5.1`、Apple Silicon `arm64`。

- `swift test --package-path . --parallel`：`272/272` 通过；其中 `AppIntegrationTests` 的 58 项集成用例通过。
- 严格并发 Debug/Release 构建均通过；`zsh -n scripts/launch-ui-check.sh` 和 `git diff --check` 通过。
- `./scripts/verify-release.sh` 通过，包含 Release probe、结构化兼容性报告、默认 arm64 App bundle 和 `codesign --verify --deep --strict`；产物版本为 `1.0.3`、build `13`。
- `memory-monitor-fixture` 直接运行及启动器正常路径、特殊路径字符路径均通过；启动器输出的 7 个存储文件权限和 240/239/12 记录数与写入器报告一致。
- 启动器通过 Launch Services 实际传递隔离环境；没有向正式实例、c3c 实例或任何真实进程发送信号。`ScratchProbe.swift` 和 `ScratchProbe 2.swift` 保持未跟踪且未修改。

## 最新 AX 证据

本轮使用隔离 bundle 做了只读的状态栏入口检查：

- 可找到标题为 `Memory Monitor 状态` 的状态栏项，角色为 `AXMenuBarItem`，子角色为 `AXMenuExtra`（状态栏 frame 约为 `(1067,3,79,24)`）；对该节点执行 AX 按压返回 `0`，并观察到面板 CG 窗口生成（一次观测为 window ID `19583`、layer `101`、bounds 约 `(1057,82,370x533)`）。
- 当前运行环境不是稳定的登录桌面会话。面板按压后，`AXWindows` 有时为空；有时唯一节点错误地返回自身 `AXApplication`，而不是 `AXWindow`/`AXSheet`。因此本轮无法稳定读取详情页成员行、审计行、滚动末端或关闭入口。
- 上述限制属于当前桌面会话和 SwiftUI `MenuBarExtra` 的 AX 暴露边界，不代表详情布局已通过或失败；本轮不保存截图，也不把状态栏入口结果扩大解释为完整详情验收。

## 证据边界与下一步

代码级契约、`NSHostingView` smoke、fixture store round-trip 和启动器隔离校验已覆盖数据、权限、长文本和只读安全门禁；真实详情页 AX 验收仍待在稳定的登录桌面会话中补做。下一阶段应使用本轮隔离 fixture，在进程详情和工作组详情中逐项确认：至少两个成员、长审计标签、顶部与末端滚动位置，以及两端均可见的关闭入口。检查过程继续只读，不点击任何进程信号控件；收尾只终止本轮输出记录的 PID 并移除本轮临时目录。

## 提交记录

- 源码、测试和启动器切片：`d075cc0`、`aa5a37a`、`bc73eb9`、`a07ba16`，均已推送至 `origin/main`。
- 本文档作为独立记录切片提交；提交前后应确认只有本文档进入提交，两个 `ScratchProbe` 文件继续保持未跟踪。
