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

1. **Slice 1（本提交）**：恢复构建；显式 store 注入；fixture fail-closed；
   内存测试/登录运行时安全开关；scratch 移入 `Scratch/`；设计文档。
2. **Slice 2**：隐藏/遮挡/失焦采样降频；`RefreshWakeup` 激活刷新。
3. **Slice 3**：死功能取舍与 `@Published` 成本收敛。
4. **Slice 4**：归因优先级/MaiBot/VM 识别与测试。
5. **Slice 5**：历史持久化/时钟回拨/文本清洗硬化。
6. **Slice 6**：Dynamic Type、滚动可达性、诊断/审计/登录 UX。
7. **Slice 7**：CI、macOS 14 迁移、发布门禁、部署版本与文档收口。

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
