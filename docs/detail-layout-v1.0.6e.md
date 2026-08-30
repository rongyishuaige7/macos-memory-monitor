# v1.0.6e 独立 UI-check 隔离与详情布局复核

## 范围

本阶段解决 v1.0.6d 留下的桌面验证缺口：

- 为独立 UI-check 提供显式、可审计的临时数据目录入口，避免依赖未记录的用户环境技巧；
- 在不触碰正式实例、c3c 实例和正式历史/审计文件的前提下，重新检查进程详情和工作组详情；
- 复核父进程关系行、成员行、审计行、指标网格、滚动末端、关闭入口和辅助功能标签；
- 继续以纯值契约和 `NSHostingView` smoke 作为无头环境门禁，不引入第三方快照或 XCUITest 依赖。

## 非目标

- 不改变正式 App 的默认存储目录、采样频率、历史保留策略或进程操作权限；
- 不向任何正式、c3c 或用户进程发送信号；
- 不把桌面人工检查伪装成 CI 自动化证明；
- 不在本阶段重做详情页信息架构或视觉主题；
- 不修改用户已有的 `ScratchProbe.swift` 和 `ScratchProbe 2.swift`。

## 架构

1. Core 层增加一个纯值的存储目录解析器。正式启动在没有显式覆盖时继续使用当前 `~/Library/Application Support/MemoryMonitor`；独立检查通过明确的测试环境变量或启动包装器传入绝对临时目录。
2. `HistoryStore.defaultFileURL` 和 `ProcessActionAuditStore.defaultFileURL` 共用该解析器，确保历史、审计及其 sidecar 文件落在同一隔离根目录；无效、空白或非绝对覆盖值回退到正式默认目录并可被单元测试验证。
3. 增加一个只用于本地验证的 bundle 构建/启动脚本：构建最新 arm64 Release、写入临时 bundle ID、设置隔离目录并输出 PID/路径；脚本不替换正式 App，也不自动执行任何进程操作。
4. 独立桌面检查仍由人工/AX 只读步骤完成。测试证据记录 bundle、隔离目录、窗口尺寸、关键标签和收尾状态；截图只保存到临时目录，不进入仓库。
5. 成员行和审计行先完成风险审计。只有在能用确定性契约证明长文本或大字号会越界时才改生产布局，并为改动增加对应 smoke/纯值测试。

### 独立启动器约定

`scripts/launch-ui-check.sh` 只接受 `--output-dir` 显式参数。目标必须是 `TMPDIR` 或 `/tmp` 下的空目录（可由 `mktemp -d` 预先创建）；脚本拒绝工作区路径、根目录、符号链接和非空目录，以免复用旧数据或覆盖正式产物。脚本在该目录下分别创建 `app-output`、`storage`、`home` 和 `tmp`，构建 Release arm64 bundle 后写入唯一的 `com.rongyi.MemoryMonitorUICheck.<timestamp>.<pid>` 标识，并通过 Launch Services 启动。

启动器对子进程设置 `HOME`、`CFFIXED_USER_HOME`、`TMPDIR` 和 `MEMORY_MONITOR_UI_CHECK_STORAGE_ROOT`，输出 `UI_CHECK_PID`、bundle 路径、隔离存储根目录、启动日志和架构等字段。它不执行 AX 点击、进程操作或任何信号调用；收尾由操作者只处理该次输出中的 PID 和 bundle。

## 风险

- 环境变量是进程级配置，必须只在显式 UI-check 启动器中设置，不能改变正常启动脚本的默认语义；
- 临时目录若被复用，旧的历史/审计内容可能影响详情展示，启动器应生成唯一目录并在记录中注明；
- SwiftUI `ViewThatFits`、AppKit AX frame 和系统字体仍随 macOS 版本变化，桌面证据只描述观察到的事实；
- 详情页可能没有足够的真实成员/历史事件来覆盖所有长值分支，缺少数据时必须保留为未验证项；
- 任何自动化点击都必须排除“请求优雅退出”“强制结束”和其他信号控件，临时 bundle 的收尾应只结束该 bundle 自身。

## 验收标准

- 默认启动和现有测试的存储路径行为不变；解析器对有效临时目录、空白、相对路径和非有限输入有确定结果；
- 独立 bundle 构建脚本只在显式临时输出目录写入，能报告 bundle ID、隔离根目录、架构和签名状态；
- `swift test --package-path . --parallel`、严格并发 Debug/Release 构建和 `./scripts/verify-release.sh` 通过；
- 最新独立 bundle 的面板、进程详情和工作组详情完成只读 AX 检查，或在文档中逐项记录无法完成的原因；
- 关系/成员/审计行和指标区域的长值、大字号、滚动末端和关闭入口都有证据来源；
- 每个代码/脚本/文档切片单独提交并推送，两个 `ScratchProbe` 文件始终未跟踪。

## 分阶段交付

1. **存储隔离解析器**：纯值解析、默认行为回归测试和最小启动参数约定。
2. **独立 bundle 启动器**：构建临时 bundle、设置隔离目录并输出可复核证据。
3. **详情布局审计**：复核成员/审计行并按证据决定是否需要生产布局修复。
4. **桌面验证交付**：完成只读 AX 检查，更新本记录，分批提交并推送。

## 实施结果

- 成员行的 stacked 分支不再把 footprint 设为水平 fixed size；它现在接受父容器提案，在单行内使用中间截断，避免极窄窗口或大字号把 trailing 文本推出容器。
- 审计行的 stacked 分支为 action、status、time 明确设置单行和中间截断；process 保持最多两行中间截断，极窄宽度不再逐字竖排。
- 审计行增加显式 AX 摘要，按 action、process、status 和本地化短时间顺序合并为一个可读元素；成员行和关系行继续保留现有合并标签。
- `DetailLayoutSmokeTests` 新增成员/审计行在 `20/40/80pt`、`.accessibility3` 下的有限宽高检查；审计行高度上限为 `120pt`，用于阻止回归到异常竖排。

## 验证记录

验证日期：2026-08-31，平台为 macOS `26.5.1`、Apple Silicon `arm64`。

- `swift test --package-path . --filter DetailLayoutSmokeTests --parallel`：退出码 `0`，新增两项 smoke 与既有用例均完成。
- `swift test --package-path . --filter DetailLayoutContractTests --parallel`：退出码 `0`，6 个契约用例完成。
- `./scripts/verify-release.sh`：通过；全量 `260/260`，严格并发 Debug/Release 构建、Release probe、结构化兼容性报告和签名 App 均通过。
- Release 产物为版本 `1.0.3`、build `13`、`arm64`，`codesign --verify --deep --strict` 通过。
- `git diff --check` 与暂存区检查通过；两个 `ScratchProbe` 文件继续保持未跟踪且未修改。

## 最新独立 AX 证据

本轮使用提交 `bfaac9e` 构建的最新隔离 bundle：

- bundle ID：`com.rongyi.MemoryMonitorUICheck.20260830184307.72340`；进程 PID：`72493`；可执行文件为 `arm64`，ad-hoc 签名校验通过。
- 启动输出目录位于系统临时目录下的 `memory-monitor-ui-check-v106f.*`；历史、审计和 sidecar 文件只出现在该实例的 `storage` 子目录。正式 `~/Library/Application Support/MemoryMonitor`、正式实例和 c3c 实例没有被操作。
- AX 找到标题为 `Memory Monitor 状态`、subrole 为 `AXMenuExtra` 的状态项并成功按压。面板窗口约 `410x605pt`；可读到采样覆盖、CPU/内存/GPU、筛选/排序、进程/工作组切换、列表和退出入口。
- 进程详情使用一个 `AXSheet`，约 `500x622pt`。顶部滚动条值为 `0.0`，分页到末端后为 `1.0`；两端都能找到 `关闭进程详情`。详情中可读到指标、身份与来源、当前工作组、父进程链、进程操作说明和滚动末端提示。
- 工作组详情使用一个 `AXSheet`，约 `540x662pt`。先回到顶部得到滚动条值 `0.0`，再分页到末端得到 `1.0`；两端都能找到 `关闭工作组详情`。详情中可读到归因说明、当前成员、成员 footprint、24 小时趋势、相关历史事件和批量操作只读提示。
- 只按压了状态项、视图切换、首个列表行、滚动分页和详情关闭入口；没有按压 `退出 Memory Monitor`、应用菜单退出、优雅退出、强制结束、取消或任何进程信号控件。

## 证据边界与后续

本轮首个进程/工作组为受保护的系统对象，采样为部分可用；该对象没有展示可操作按钮，工作组成员数为 `1`，审计列表也没有真实长事件。因此，审计长文本的桌面 AX 结果仍不宣称已覆盖，当前结论来自生产源码检查和极窄 `NSHostingView` smoke。下一阶段应继续用隔离数据构造包含多条长审计事件和多个成员的只读详情 fixture，再验证其 AX 合并标签和末端可见性；不向真实用户进程发送信号。

## 提交记录

- 源码与测试批次：`bfaac9e`（`fix: constrain detail member and audit rows`），已推送至 `origin/main`。
- 本文档为独立验证批次，提交后应确认只包含本文档；两个 `ScratchProbe` 文件继续保持未跟踪。
