# v1.0.6g：隔离 UI-check 启动配置一致性

## 范围

本阶段收敛 UI-check 的两个进程级环境变量：

- `MEMORY_MONITOR_UI_CHECK_FIXTURE=1`：选择确定性的合成采样器；
- `MEMORY_MONITOR_UI_CHECK_STORAGE_ROOT=<temporary path>`：选择隔离的历史/审计存储根目录。

两项配置必须作为一个启动配置解析。只有当两个值都存在、格式有效且存储根目录位于 `TMPDIR` 或 `/tmp` 下时，App 才进入 fixture 模式并使用该根目录；任一项缺失、空值、非法或不匹配，都回退到生产 `MonitorSampler` 和默认 Application Support 存储。这样可以阻止合成数据写入正式历史，也阻止真实采样意外写入临时目录。

## 非目标

- 不改变正式启动的默认存储目录、采样器、采样频率或进程操作策略；
- 不改变 `MemoryMonitorStoragePaths.rootURL(overridePath:)` 的纯值解析兼容行为；
- 不允许手工环境变量绕过启动器对临时目录、符号链接、权限和空目录的校验；
- 不在无头会话中伪造详情页 AX 验收，也不向任何真实进程发送信号；
- 不修改用户已有的 `ScratchProbe.swift` 和 `ScratchProbe 2.swift`。

## 架构

1. Core 增加一个纯值的 isolated-root 校验入口。它规范化绝对路径、拒绝根目录和 NUL 字符，并按传入环境中的 `TMPDIR` 与系统 `/tmp` 做路径边界检查；符号链接和竞态安全仍由启动器的文件系统校验负责。
2. App delegate 通过单一 `LaunchConfiguration` 解析 sampler 模式和 storage root。正常配置返回生产 sampler/默认 root；成对有效配置返回 fixture sampler/隔离 root；其他组合全部 fail closed。
3. App delegate 显式把解析后的 root 传给 `HistoryStore` 和 `ProcessActionAuditStore`，避免 Swift 默认参数分别读取进程环境而产生混合状态。fixture 与生产操作控制器仍共享现有安全策略。
4. 启动器继续同时设置并校验两个变量；本阶段不扩大其输出内容，只增加 App 侧的防御和纯值回归测试。

## 风险

- `TMPDIR` 本身可能是符号链接或带尾部斜杠，校验必须比较规范化路径和完整组件边界，不能使用简单前缀匹配；
- 测试环境不能依赖修改全局 `ProcessInfo`，所有解析测试都应传入显式字典；
- 回退路径必须同时回退 sampler 和两个 store，不能只切换其中一个；
- 生产默认 root 可能与某些测试 fallback 相同，测试应使用可识别的 fallback URL 验证是否真正采用隔离 root；
- 启动器已经验证目录权限和符号链接，但 App 侧不能把纯值校验误写成完整的 TOCTOU 防护。

## 验收标准

- 无环境、只有 fixture 开关、只有 storage override、非法/相对/非临时 root、非 `1` fixture 值，均得到生产 sampler 和默认 root；
- 只有成对有效环境才得到 fixture sampler 和规范化临时 root；
- `HistoryStore` 与 `ProcessActionAuditStore` 在同一解析结果下使用同一 root；
- 现有 `MemoryMonitorStoragePaths` 单元测试和完整 App/Core 测试保持通过；
- 严格并发 Debug/Release 构建、`verify-release.sh` 和启动器语法检查通过；
- 每个设计、源码/测试、验证文档切片单独提交并推送，两个 `ScratchProbe` 文件保持未跟踪。

## 分阶段交付

1. **设计契约**：记录成对环境、回退语义和路径边界。
2. **Core 路径校验**：增加临时 root 纯值解析及测试。
3. **App 统一工厂**：让 sampler、history、audit 从同一启动配置创建，并补充混合环境回归测试。
4. **验证交付**：运行全量门禁，更新本记录；真实详情 AX 检查仍在稳定登录桌面会话中单独进行。

## 实施结果

- Core 新增 `MemoryMonitorStoragePaths.isolatedRootURL(environment:)`：对显式 storage root 做绝对路径、NUL/换行、根目录和规范化临时目录边界校验；`MemoryMonitorUIFixture.isolatedStorageRootURL` 要求 fixture 开关与该 root 成对出现。
- App 新增 `MemoryMonitorLaunchConfiguration`，一次解析 sampler 模式和 storage root。只有成对有效配置才选择 `MemoryMonitorUIFixtureSamplingSource`；缺失、非法或不匹配的任一项都会同时回退到生产 `MonitorSampler` 和默认 Application Support root。
- `MemoryMonitorApplicationDelegate.makeModel(environment:)` 显式把同一个解析 root 传给 `HistoryStore` 与 `ProcessActionAuditStore`，不再让两个 store 通过默认参数分别读取进程环境。测试还可注入固定 `dateProvider`，避免 shutdown retention 依赖真实墙钟。
- Core/App 回归测试覆盖无环境、单项环境、非法值、路径规范化、临时目录边界，以及 fixture 模式下 history/audit 同根持久化；模型工厂测试在第一次刷新前用 `guard` 强制确认 `usesUIFixture`。

## 验证记录

验证日期：2026-08-31，平台为 macOS `26.5.1`、Apple Silicon `arm64`。

- `swift test --package-path . --parallel`：`276/276` 通过。
- 配置相关 targeted tests：App 3 项、Core fixture 7 项、storage path 7 项全部通过。
- `swift build --package-path . --configuration debug -Xswiftc -strict-concurrency=complete`：通过。
- `swift build --package-path . --configuration release -Xswiftc -strict-concurrency=complete`：通过。
- `zsh -n scripts/launch-ui-check.sh` 与 `git diff --check`：通过。
- `./scripts/verify-release.sh`：通过；Release probe、结构化兼容性报告、默认 App bundle 构建和 `codesign --verify --deep --strict` 均通过。产物版本为 `1.0.3`（build `13`），报告架构为 `arm64`。
- 修复后的模型工厂测试只在临时 root 中生成 history/audit 文件；正式存储目录的 mtime 与校验值在随后验证中保持不变。

## 数据保护与证据边界

首次运行模型工厂测试时，测试环境遗漏 `TMPDIR`，按设计触发了 fail-closed 回退，曾把一次固定时间的测试刷新写到正式存储并重建为空状态。发现后立即停止该路径，已对当前正式文件做窄范围、保留权限的本地副本；该副本与当时正式文件一致，但没有独立 provenance，不能证明包含测试前历史。

只读核查未发现可确认的 Time Machine/APFS、废纸篓或常见本地备份快照，因此没有执行恢复，也没有把 fixture 临时数据当作正式数据恢复源。后续测试保留 `TMPDIR` 注入和 fixture-mode `guard`，防止同类回退再次触碰正式 root。

## 后续

- 在稳定的登录桌面会话中继续完成隔离 bundle 的真实详情页 AX 检查；无头会话不作为 AX 证据。
- 评估是否需要把 `TMPDIR` 的信任边界进一步收紧为启动器产生的临时根，并为任何收紧规则补充跨平台路径测试。

## 提交记录

- 源码与测试批次：`a564f6f`（`fix: pair ui fixture storage configuration`），已推送至 `origin/main`。
- 本文档为独立验证记录批次；两个 `ScratchProbe` 文件及其他未跟踪用户文件未加入提交。
