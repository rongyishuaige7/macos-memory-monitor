# v1.0.6i：详情数据目标语义验证记录

验证日期：2026-08-31。验证在 `/Users/rongyi/Desktop/memory-monitor` 完成，未修改正式 Application Support、登录项、TCC/隐私权限或既有桌面实例。

## 交付内容

- `MonitorDetailDataStatus.resolve` 增加必填的 `targetPresent` 输入，并在采样质量判定前处理目标消失：目标缺失且仍有其他保留条目时返回 `.retained/.targetUnavailable`；没有保留条目时返回 `.unavailable` 且不携带保留原因。
- 进程详情和工作组详情分别以当前 `process(for:)`、`group(for:)` 结果传入目标存在性。目标消失时 banner 不再显示“当前进程采样”或“当前采样部分可用”，正文继续保持只读安全边界。
- 进程详情的操作区改为“最近操作记录（全局）”，并明确审计日志不保存 PID、启动时间或路径，因而不按当前进程名称猜测归属。

## 自动化验证

- `swift test --package-path . --filter AppIntegrationTests/testMonitorDetailDataStatus`：4/4 通过；覆盖 current、partial、loading、background、失败/无数据、无效时间，以及目标消失但全局仍有条目和无保留条目。
- `swift test --package-path . --parallel`：280/280 通过。
- `swift build --package-path . --configuration debug -Xswiftc -strict-concurrency=complete`：通过。
- `swift build --package-path . --configuration release -Xswiftc -strict-concurrency=complete`：通过。
- `./scripts/verify-release.sh`：通过；包含全量测试、严格 Debug/Release 构建、Release probe、结构化兼容性报告、默认 App bundle 构建和 `codesign --verify --deep --strict`。
- `git diff --check`、`zsh -n scripts/launch-ui-check.sh`：通过。

## 证据边界

- 两个详情调用点已完成源码复核；本阶段没有新增 SwiftUI/AX 视图级断言来读取最终 banner 文案或真实窗口树，因此不能把当前桌面会话的 AX 详情验收宣称为通过。
- 当前会话中保留的 PID `30631` 仍对应既有隔离 UI-check 可执行路径；本阶段未向其发送信号，也未启动或终止它。真实详情页成员、长审计文本、滚动末端和关闭入口仍待稳定登录桌面会话只读复核。
- `ScratchProbe.swift`、`ScratchProbe 2.swift` 及既有 `TemporaryDirectory.*` 未跟踪项仍保留，未加入提交。

## 提交与推送

- `c9e38b7 docs: define detail semantics v1.0.6i`：设计契约，已推送至 `origin/main`。
- `b9be7a9 fix: clarify missing detail targets`：源码、详情文案与回归测试，已推送至 `origin/main`。
- `ad7377e fix: keep detail retention reason scoped`：收口 `.unavailable` 的保留原因不变量，已推送至 `origin/main`。
- 本验证记录作为独立文档提交并推送；完成后进入 v1.0.6j 的菜单栏可达性与登录启动状态订阅设计。

