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

## 分阶段交付

1. **设计与边界**：记录 fixture 数据、开关、只读安全门禁和验证标准。
2. **数据工厂与写入器**：复用 Codable/store API 生成临时历史和审计数据，并增加值级测试。
3. **App fixture 采样模式**：显式开关下注入稳定多成员快照，增加默认路径回归测试。
4. **启动器与桌面证据**：预置数据、启动隔离 bundle，完成真实 AX 导航和文档记录。

