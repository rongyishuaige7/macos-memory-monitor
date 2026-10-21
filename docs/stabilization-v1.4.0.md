# Stabilization v1.4.0

## Scope

把 v1.3.1 之后暴露的运行安全、测试隔离、长期采样成本、归因准确性和
可访问性问题收敛为一组可独立回退的切片。目标版本为 1.4.0，但在全部
切片验收完成前不修改 `Resources/Info.plist` 的发布版本。

本系列覆盖：

- 恢复当前工作区构建，清理不参与编译的 scratch 噪声；
- 测试与 UI-check fixture 不得读写真实用户数据，也不得触发真实清理、
  内存测试或登录项注册；
- 隐藏、遮挡或失焦的桌面窗口不得继续使用面板级采样频率；
- 对不再被生产 UI 使用的建议/历史分析/详情组件做取舍，避免死功能
  持续消耗 CPU 与 SwiftUI 刷新；
- 修正 MaiBot/虚拟机/Ghostty 的归因优先级与识别覆盖；
- 硬化历史持久化的规范化、时钟回拨和文本清洗边界；
- 恢复生产视图的 Dynamic Type、滚动可达性和诊断信息；
- 修复 CI、发布门禁、部署版本和文档漂移。

## Non-goals

- 不新增网络、遥测、远程监控或自动更新；
- 不改变 24 小时历史、7 天审计、3/5/20 秒采样策略的产品默认值；
- 不引入第三方依赖或新的数据库；
- 不重写进程信号安全策略，不扩大可操作进程范围；
- 不在本系列中启用 Developer ID、notarization 或 App Sandbox；
- 不删除用户数据、旧 release bundle 或 scratch 文件；需要清理时只做
  可逆移动并单独确认。

## Architecture

### 1. Explicit stores and test isolation

`MonitorViewModel` 不再提供默认的 `HistoryStore`/`ProcessActionController`。
生产入口 `MemoryMonitorApplicationDelegate.makeModel` 显式构造应用支持
目录下的 store；测试必须通过 `TestSupport.swift` 的临时 store 或自己的
临时 URL 注入。`cleanupExecutionEnabled` 的默认值改为 `false`，生产工厂
显式传 `true`。

这样可以消除 `swift test` / `verify-release.sh` 在普通开发机上修剪或
重写真实 `history.json`、`actions.jsonl` 的路径。

### 2. Fixture capabilities and fail-closed launch

`MemoryMonitorLaunchConfiguration` 增加 `fixtureRequested`：

- 显式 fixture flag + 可信临时根：fixture 采样、临时存储、关闭清理、
  只读登录运行时、关闭内存测试；
- 显式 fixture flag 但根缺失/不可信：不再静默回退生产，而是生成
  `MemoryMonitorFixtureFallback-*` 临时根，继续使用 fixture 采样并关闭
  全部破坏性能力；
- 没有 fixture flag：保持生产行为。

`ReadOnlyLoginLaunchRuntime` 只报告不可用并拒绝注册；`MemoryTestController`
增加 `executionEnabled`，默认关闭，生产 `DesktopWindowCoordinator` 显式
开启。

### 3. Hidden-window sampling

计划把 `isDesktopPresented` 从“窗口存在”改为“窗口可见、未遮挡且 App
活跃（或菜单栏面板打开）”。观察 `didHide/didUnhide`、
`didChangeOcclusionState`、`didBecomeActive/didResignActive`，激活时通过
`RefreshWakeup` 立即刷新。隐藏/失焦时回落到后台 20 秒系统采样、60 秒
进程扫描。

### 4. Dead features and runtime cost

计划二选一处理：

- 恢复单条建议卡/历史事件/工作组详情入口；或
- 删除 App 侧 `RecommendationEngine`、`lastError`、CPU/GPU fraction、
  `historyAnalysis` 及对应死视图/测试。

无论哪种选择，都不允许继续每轮重发不可见 `@Published` 状态。

### 5. Grouping correctness

计划调整 `WorkloadGrouper`：

- 具体身份（MaiBot、虚拟机）优先于 `ancestorHasGhostty`；
- MaiBot 使用 `workingDirectoryLabel` 与祖先链；
- 虚拟机增加常见 app/bundle/路径识别和祖先链；
- 为 MaiBot/Ghostty/VM/UTM/Parallels/QEMU 增加测试。

### 6. Persistence hardening

计划处理：

- load/merge 也强制 top 40 workload；
- 旧 `containsEstimatedFootprint` 缺失值的语义；
- persisted workload title 的 bidi/零宽字符清洗；
- `MemoryHistoryAnalyzer` 输入校验；
- 时钟回拨 + fallback history 的合并；
- 锁文件 `O_CLOEXEC`。

### 7. Accessibility and UX

计划：

- 生产视图使用相对字号/`@ScaledMetric`，大字号下可滚动；
- `ProcessDetailView`、`DesktopMenuPanel` 的可达性；
- 设置页恢复 `item.detail`、overall/checkedAt、登录项/隐私快捷入口；
- audit refresh/retry、登录更新取消；
- 保存 process query/sort/history range；
- 菜单栏压力色的实机确认和双编码。

## Risks

- 显式 store 注入会改变测试构造方式；需要编译器保证没有遗漏。
- fixture fail-closed 会改变“lone flag 回退生产”的既有测试语义。
- 隐藏窗口降频可能让用户切回窗口时看到短暂旧数据；激活即刷新可缓解。
- 删除死功能会减少测试数量；必须保留 Core 的纯逻辑测试。
- 归因顺序调整可能改变现有分组；需要新增测试锁定优先级。
- 历史清洗/兼容性改动必须保持 v1 文件可读。

## Verification

每个切片至少执行：

```bash
swift build --disable-sandbox --package-path . --scratch-path /tmp/memory-monitor-review-build
swift test --disable-sandbox --package-path . --scratch-path /tmp/memory-monitor-review-build
```

并记录：

- 受影响行为的窄测试；
- 全量逻辑测试结果；
- 原生 AppKit 用例是否因无前台桌面而跳过/失败；
- `git diff --check`；
- 不修改真实 `~/Library/Application Support/MemoryMonitor` 的确认；
- 需要时的 Release 构建和 app bundle 签名验证。

## Staged delivery

1. **Slice 1（已完成）**：恢复构建；显式 store 注入；fixture fail-closed；
   内存测试/登录运行时安全开关；scratch 移入 `Scratch/`；设计文档。
2. **Slice 2（已完成）**：隐藏/遮挡/最小化/关闭/切 Space 采样降频；
   `DesktopPresentationPolicy` 纯策略与窗口生命周期观察。
3. **Slice 3（已完成）**：未使用 `@Published` 状态收敛；删除不可达的
   `lastError`/采样描述属性；推荐与 CPU/GPU fraction 保留但不再发布。
4. **Slice 4（已完成）**：MaiBot/虚拟机优先于 Ghostty 子树；MaiBot
   working-directory/祖先识别；常见 VM 应用/helper 名称与 bundle 识别。
5. **Slice 5（已完成）**：load/merge 强制 top-40 workload 且 compaction
   idempotent；persisted title/id 清洗 bidi/控制符；analyzer 过滤无效
   availableFraction；时钟回拨时丢弃无法被新时钟接受的 fallback 记录；
   锁文件 `O_CLOEXEC`。
6. **Slice 6a（已完成）**：设置诊断详情/整体状态/检查时间、登录项与隐私
   快捷入口、登录取消、审计刷新与重试、审计搜索/时间、进程详情原因可见。
   **Slice 6b（已完成）**：Dynamic Type/相对字号、进程详情滚动与操作
   按钮回退、菜单面板滚动与固定退出 footer、进程/历史/释放/测试页字号
   与行高收敛、图表可访问性摘要。
7. **Slice 7（已完成）**：CI 迁移到 macOS 15、CI 显式跳过原生 GUI 用例、
   macOS 14 URL 尾斜杠测试修复、README 的 Dock/版本描述与兼容性矩阵说明
   收口；macOS 15 CI 已跑通（run `39596314922`、`39598034930`）。
8. **Slice 8（已完成）**：删除旧 popover、健康面板、工作组详情、历史面板、
   `DetailLayout`/`PopoverLayout` 及其测试；移除 App 侧无 UI 的推荐计算
   与状态。Core `RecommendationEngine` 保留给 probe/未来入口，历史分析
   Core API 保留为有测试的只读能力。旧 bundle 已备份清理，`Info.plist`
   提升到 1.4.0（140），本地 bundle 已部署并保留登录项。

## Slice 1 verification

- `swift build` 在清理 `Sources/MemoryMonitorApp/DesktopRelease 2.swift`
  后通过。
- `swift test`：327 项，325 通过；失败仅
  `DesktopMotionTests` 与 `SmartCleanupNativeTests` 两个原生 GUI 用例，
  原因是当前自动化 shell 无前台桌面/LaunchServices fixture 启动能力。
- 所有 `MonitorViewModel` 测试构造均注入临时 store；真实
  `history.json`/`actions.jsonl` 的修改时间在测试前后保持为
  2026-10-13，未被本次测试改写。
- fixture 测试覆盖：lone flag 生成临时根、关闭清理、只读登录；
  `MemoryTestController` 默认禁用。

## Slice 2 verification

- `DesktopPresentationPolicy` 覆盖关闭、不可见、最小化、完全遮挡和 App
  隐藏；只有可见、未最小化、未遮挡且未隐藏的窗口才请求面板级采样。
- `DesktopWindowCoordinator` 观察 `didChangeOcclusionState`、
  `didHide/didUnhide`、`didBecomeActive/didResignActive` 和
  `activeSpaceDidChange`；窗口关闭/最小化时回落后台频率，重新可见时
  恢复。
- `swift test`：328 项，326 通过；失败仅 `DesktopMotionTests` 与
  `SmartCleanupNativeTests` 两个原生 GUI 用例，原因同上。
- Release 严格并发构建通过。

## Slice 3 verification

- `recommendation`、`cpuUsageFraction`、`gpuUsageFraction` 和
  `isPanelPresented` 改为非 `@Published` 状态：仍可供测试/未来 UI 读取，
  但不再每轮触发整棵 SwiftUI 视图失效。
- 删除无生产调用的 `lastError`、`processObservationDescription`、
  `samplingIssueDescription`、`samplingNoticeDescription`、
  `samplingCadenceDescription`、`samplingDiagnosticsDescription`。
- `swift test`：328 项，逻辑测试全部通过；失败仅三个原生 GUI 用例
  （`CleanupMotionTests`、`DesktopMotionTests`、`SmartCleanupNativeTests`），
  均为当前 shell 无前台桌面/LaunchServices 能力导致。
- Debug 与 Release 严格并发构建通过。

## Slice 4 verification

- MaiBot/虚拟机检查移到 `ancestorHasGhostty` 之前；MaiBot 增加
  `workingDirectoryLabel` 与祖先链识别；虚拟机增加 UTM、Parallels、
  VMware、VirtualBox、QEMU、Lima、Colima、Multipass 等常见名称/bundle。
- 新增 6 个测试：MaiBot over Ghostty、MaiBot Python by working directory、
  VM over Ghostty、常见 VM 应用集合、`maibot-backup`/`utm-project` 反例、
  Ghostty 下普通 Node 运行时仍归 Ghostty。
- `swift test`：334 项，332 通过；失败仅 `DesktopMotionTests` 与
  `SmartCleanupNativeTests` 两个原生 GUI 用例，原因同上。
- Debug/Release 严格并发构建通过。

## Slice 5 verification

- `HistoryStore` load/merge 现在都经过 `compactingWorkloads`；旧文件或
  recovery merge 中超过 top-40 的 workload 会被压缩为 top-40 + 两个聚合。
  `compactedWorkloads` 对已有 `other-*` 聚合保持幂等。
- `PersistedWorkloadRecord` decode 清洗 bidi/控制符、路径分隔符和空白；
  `MemoryHistoryAnalyzer` 忽略非有限/越界的 `availableFraction`。
- 大幅时钟回拨时，`fallbackRecordsForNewClock` 丢弃无法被新时钟接受的
  记录，避免 `HistoryStore.merge` 整批失败；持久化锁文件增加
  `O_CLOEXEC`。
- 新增测试：compaction 幂等、merge/load legacy >40 workload、bidi 清洗、
  fallback 未来记录过滤。
- `swift test`：338 项，337 通过；失败仅 `SmartCleanupNativeTests`
  原生 GUI 用例（当前 shell 无 LaunchServices fixture 启动能力）。
- Debug/Release 严格并发构建通过。

## Slice 6a verification

- 设置页诊断显示整体健康、检查时间、每项原因详情；新增“打开登录项设置”
  和“查看隐私设置”入口；登录更新中提供取消。
- `ProcessActionController.refreshAudit()` 先等待初始加载，再执行显式
  重载，修复“刷新被初始任务代际丢弃”的竞态；审计面板新增刷新/重试。
- 审计搜索覆盖操作名与状态；记录时间改为日期+时间；进程详情显示
  “不支持退出”的具体原因和跨进程忙碌提示；菜单栏面板增加“统计”入口和
  审计错误提示。
- `swift test`：339 项，338 通过；失败仅 `SmartCleanupNativeTests`。
- Debug/Release 严格并发构建通过。

## Slice 6b verification

- 生产视图从大量固定 point size 改为 `.title2/.headline/.subheadline/
  .caption/.caption2` 等相对样式；内存仪表百分比使用
  `@ScaledMetric`；进程行由固定高度改为 `minHeight`，避免大字号裁切。
- `ProcessDetailView` 改为 ScrollView + 240/420/560 高度边界；操作按钮
  使用 `ViewThatFits` 在窄宽度/大字号下回退为纵向排列。
- `DesktopMenuPanel` 主体可滚动、退出 footer 固定；菜单面板字号改为
  `.callout`。
- `MemoryTrend` 增加“内存使用率趋势”可访问性标签与样本/平均/最高摘要。
- 新增 `detail-accessibility` 和 `desktop-menu-accessibility` 渲染检查。
- `swift test`：339 项，338 通过；失败仅 `SmartCleanupNativeTests`
  原生 GUI 用例。
- Debug/Release 严格并发构建通过。

## Slice 7 verification

- GitHub Actions 兼容性矩阵移除已退役的 `macos-14`，保留 `macos-15`
  / Xcode 16.4；CI 设置 `SWIFT_TEST_SKIP`，显式跳过需要前台桌面和
  LaunchServices 的原生 GUI 用例，纯逻辑测试仍全量执行。
- `verify-compatibility.sh` 支持 `SWIFT_TEST_SKIP`；`zsh -n` 语法检查
  通过。
- `StoragePathTests` 与 `AppIntegrationTests` 的 URL 比较改为 `.path`，
  避免 macOS 14 的尾斜杠表示差异导致误报。
- README 更新为“LSUIElement 启动、打开主窗口时切 regular/Dock”，并
  修正默认 bundle 版本为 1.3.1 / 131；兼容性矩阵增加 macOS 14 退役与
  macOS 15 CI 说明。
- GitHub Actions 计费已恢复；`macos-15` / Xcode 16.4 CI 两次通过：
  run `39596314922`（ScreenCaptureKit 兼容修复）、`39598034930`
  （死代码清理后）和 `39599217590`（1.4.0 / 140）。产物 `compatibility-macos-15-arm64` 显示
  macOS 15.7.9 arm64、system estimated、CPU available、GPU unavailable
  （hosted VM），进程 283/525（53.9%）。
- 旧 bundle 清理与 1.4.0 本地部署已完成；Developer ID/notarization 仍未执行。

## Slice 8 verification

- App 侧删除约 4,600 行不可达代码：`MonitorPopover`、`MonitorHealthPanel`、
  `WorkloadGroupDetailView`、`HistoryPanel`、`DetailLayout`、
  `PopoverLayout` 及其测试。
- 保留 `ProcessDetailView`、设置页健康诊断、审计面板和
  `SimpleMonitorPresentation`；Core `RecommendationEngine` 继续供
  `memory-monitor-probe` 使用。
- 推荐相关 App 测试删除；Core 推荐/历史分析测试保留。
- `swift test`：307 项，305 通过；失败仅 `DesktopMotionTests` 与
  `SmartCleanupNativeTests`（无前台桌面/LaunchServices）。
- Debug/Release 严格并发构建通过；CI run `39598034930` 通过。
- 1.4.0 版本提交后 CI run `39599217590` 通过；产物为 1.4.0 (140)，
  macOS 15.7.9，进程 262/490（53.47%），CPU available、GPU unavailable。

## Local 1.4.0 release verification

- `Resources/Info.plist`：`1.4.0 / 140`；Release arm64 binary 使用
  Apple Development 签名并通过 `codesign --verify --deep --strict`。
- 已部署到登录项注册的路径
  `~/Library/Application Support/MemoryMonitor/releases/1.3.1-final/MemoryMonitor.app`；
  `~/Applications/MemoryMonitor.app` 指向该 bundle 的符号链接，避免同
  bundle ID 多副本。
- `sfltool dumpbtm` 复核：`MemoryMonitor` 登录项仍为
  `enabled, allowed, notified`，URL 指向上述路径，Generation 12；未执行
  登录/登出实测。
- 旧 1.0.3、1.1.0、1.2.0、1.2.1、1.3.0 和旧 1.3.1 bundle 已移入
  `~/Library/Application Support/MemoryMonitor/backup-1.4.0-migration/`，
  可回滚；未删除用户数据。
- 保留 `1.3.1-final` 目录名是为了不破坏已批准的登录项 URL；实际内容为
  1.4.0。Developer ID/notarization、TCC 权限变化和登录实测仍未执行。
