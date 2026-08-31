# v1.0.6j：菜单栏弹窗可达性验证记录

验证日期：2026-08-31。验证在 `/Users/rongyi/Desktop/memory-monitor` 完成；未修改正式 Application Support、登录项、TCC/隐私权限或既有桌面实例，也未触碰现有隔离 UI-check 进程。

## 交付内容

- `MonitorPopover` 直接注入并观察 `LoginLaunchCoordinator`，健康图标、健康 sheet、详情操作和审计 sheet 复用同一组协调器实例；弹窗出现及应用重新激活时主动刷新登录启动状态。
- 页眉、视图切换器和 footer/退出入口位于中央内容滚动区之外；实时/历史内容通过 `MonitorPopoverContentScroll` 受限于策略 viewport，长内容不会把退出入口推离弹窗。
- 新增 `MonitorPopoverLayoutPolicy`，集中管理宽度、最大高度、最小内容高度和异常尺寸清洗；增加长内容 `NSHostingView` fixture 与登录启动状态发布测试。
- footer 和中央滚动区分别提供 `monitor-popover-footer`、`monitor-popover-content` accessibility identifier，供后续稳定桌面会话只读复核。

## 自动化验证

- `swift test --package-path . --filter PopoverLayoutContractTests --parallel`：7/7 通过。
- `swift test --package-path . --filter AppIntegrationTests/testLoginCoordinatorPublishesExternalStatusRefresh`：通过。
- `swift test --package-path . --parallel`：第二次完整运行 288/288 通过；首次并行运行有 1 项既有异步测试 `testMonitorViewModelHealthCheckTimestampWaitsForSampling` 超时，单独重跑通过，随后完整运行和发布门禁均通过。
- `swift build --package-path . --configuration debug -Xswiftc -strict-concurrency=complete`：通过。
- `swift build --package-path . --configuration release -Xswiftc -strict-concurrency=complete`：通过。
- `./scripts/verify-release.sh`：通过；包含全量测试、严格 Debug/Release 构建、Release probe、结构化兼容性报告、默认 App bundle 构建和 `codesign --verify --deep --strict`。
- 发布脚本摘要：App `1.0.3 (build 13)`；probe 为 `完整采样`，进程 `423/629 enumerated (部分可用)`；兼容性 schema `1`、macOS `26.5.1`、arm64。
- `git diff --check`、staged diff 检查和 Swift 语法/严格并发编译：通过。

## 证据边界

- 布局契约和 `NSHostingView` fixture 证明中央滚动区在受限尺寸下有有限高度，且 footer 仍在布局树中；它们不等同于真实菜单栏窗口的鼠标滚轮、键盘或 AX 滚动行为。
- 本批没有在当前不稳定登录桌面 AX 会话中启动、重启或操作 UI-check bundle，因此不宣称真实窗口的 footer 末端、应用激活刷新和嵌套历史滚动已通过实机验收。后续桌面复核应使用独立临时 bundle，只读确认 `monitor-popover-content`、`monitor-popover-footer` 和“退出 Memory Monitor”均可达。
- `ScratchProbe.swift`、`ScratchProbe 2.swift` 及既有 `TemporaryDirectory.*` 未跟踪项仍保留，未加入提交。

## 提交与推送

- `d8ea37e docs: define popover reachability v1.0.6j`：设计契约，已推送至 `origin/main`。
- `4b4ebc9 fix: keep popover footer reachable and observe login state`：源码与测试，已推送至 `origin/main`。
- 本验证记录作为独立提交推送后，本阶段结束；不自动进入下一阶段。
