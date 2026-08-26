# Memory Monitor

个人 macOS 内存进程监视器设计与实施方案。

- 目标设备：当前这台 Apple Silicon Mac
- 物理内存基线：16 GiB
- 首版形态：菜单栏常驻 + 点击弹出详细面板
- 首版范围：只监视、分析和给出建议，不执行进程退出或强制结束
- 后续范围：在明确授权和安全校验之后，增加当前用户进程的优雅退出与强制结束
- 文档状态：设计基线，可作为后续实现的验收依据

## 1. 产品定位

这不是一个把 `top` 搬到图形界面的通用进程列表，而是一个面向个人工作流的“内存状态解释器”。它需要快速回答：

1. 当前内存压力是否正在影响工作；
2. 哪一组工作任务造成了压力；
3. 哪些对象值得优先处理，以及处理后可能释放什么；
4. 当前看到的数字是实际常驻内存、压缩内存，还是共享/交换造成的 footprint。

首屏应该围绕“现在最该关注什么”组织，而不是让用户先理解数百个 PID。

## 2. 当前机器的设计依据

已观察到的运行状态：

- 设备总内存为 16 GiB；
- 物理内存曾长期接近耗尽，压缩内存约 3–7 GiB；
- swap 曾从约 6 GiB 膨胀到 30 GiB 以上，说明压力具有持续性和累积性；
- Codex 的 headless Chrome、Node 子进程和浏览器自动化任务曾是最大压力来源；
- 虚拟机、Ghostty、Safari/WebKit、MaiBot 和多个 Codex 会话是常见的次级来源；
- `kernel_task`、`WindowServer`、系统 WebKit helper 会在列表中显得很大，但通常不是可直接处理的用户对象；
- macOS `top` 的 `MEM` 是 footprint 口径，和 RSS 不同，不能把各行直接相加。

由此得到的产品要求：

| 观察到的问题 | 设计响应 |
| --- | --- |
| 大量 helper 淹没真正的工作任务 | 按应用、父子树、自动化 profile 和工作目录聚合 |
| swap 数字上涨很慢但后果严重 | 记录 swap 增量速率和趋势，而不是只显示总量 |
| 系统进程看似可清理 | 明确标记系统对象和保护对象，默认折叠 |
| footprint 与 RSS 容易混淆 | 同时显示两种口径，并解释差异 |
| 进程会自动重启 | 记录父进程、启动时间和工作组，提示“可能被重新拉起” |
| 个人工作状态变化快 | 用最近 1–5 分钟趋势和事件时间线辅助判断 |

## 3. 目标与非目标

### 3.1 首版目标

- 菜单栏常驻，空闲时几乎无感；
- 一眼看到内存压力等级、可用内存、压缩内存和 swap；
- 将进程折叠为可理解的工作组；
- 找出高占用、快速增长和高交换活动的对象；
- 给出带原因和预期收益的建议；
- 支持本地 24 小时磁盘历史，帮助判断“正在恢复”还是“又在恶化”；
- 无网络依赖、无遥测、无自动结束进程。

### 3.2 首版明确不做

- 不实现远程主机监控；
- 不实现 Windows/Linux 兼容；
- 不实现自动 kill、自动清缓存或自动重启应用；
- 不删除应用文件、配置文件或临时目录；
- 不把完整命令行、URL、环境变量或凭据写入历史；
- 不追求 Activity Monitor 的全部功能，例如磁盘、网络、能耗的完整分析。

## 4. 典型个人工作场景

### 场景 A：Codex 浏览器自动化失控

多个 headless Chrome helper 和 Node 子进程持续增长，swap 快速增加。界面应将它们合并为一个“Codex 自动化”工作组，并显示子进程数、调试端口数量、增长趋势和建议停止对象。

### 场景 B：开发服务与终端长期运行

Ghostty 中的构建、日志或 Python 服务长时间运行。界面应显示工作目录名称、所属终端和最近 CPU/内存趋势，避免用户误关仍在工作的任务。

### 场景 C：虚拟机占用突然升高

虚拟机进程可能一次占用数 GiB。界面应将其标为高优先级用户工作组，同时区分“正在运行的虚拟机”和系统服务。

### 场景 D：内存已释放但 swap 未立即回落

用户关闭大进程后，物理内存恢复但 swap 仍高。界面应显示“压力已下降，swap 正在回收”，避免误以为清理失败。

## 5. 信息架构与界面

### 5.1 菜单栏状态

菜单栏只显示一个紧凑状态，不显示大量数字。建议格式：

`RAM 78% · swap 5.8G · 注意`

状态颜色和图标只表达等级：

- 正常：中性颜色；
- 注意：琥珀色；
- 严重：红色；
- 采集受限：灰色并标注原因。

点击后打开 360–440 px 宽的 popover。采样频率会随面板可见性和压力状态调整：面板打开时加快，面板关闭且压力正常时降频，压力异常时保持较快观察；历史按分钟写盘。

### 5.2 弹出面板布局

1. **当前状态条**
   - 压力等级；
   - 可用内存；
   - 压缩内存；
   - swap 已用/剩余；
   - 最近趋势和 24 小时历史窗口。

2. **现在最该关注**
   - 最多 3 条建议；
   - 每条包含原因、证据、影响范围和建议动作；
   - 首版动作仅为“查看详情”“忽略此组”“稍后提醒”。

3. **工作组列表**
   - 默认按“可操作性 × footprint × 增长速度”排序；
   - 显示应用图标、工作组名、总 footprint、RSS、CPU、子进程数和 5 分钟趋势；
   - 系统组默认折叠。

4. **事件时间线**
   - 记录压力等级变化、工作组启动/退出、swap 越过阈值和建议生成；
   - 只保留本地 24 小时磁盘历史。

### 5.3 工作组详情

详情页显示：

- 工作组的归属依据；
- 根进程、父进程链和子进程数量；
- footprint、resident、压缩估计和 CPU 趋势；
- 最近 5 分钟内存曲线；
- 是否属于系统保护对象；
- 当前建议及其置信度。

首版不显示完整命令行。若必须辅助识别，只显示经过脱敏的标签，例如“headless”“临时 profile”“端口 9334”，不保存原始参数。

## 6. 指标定义

### 6.1 系统指标

- `total`: `hw.memsize`；
- `free`: 当前空闲页；
- `available_estimate`: `free + inactive + purgeable` 的估算值（Darwin 的 `free_count` 已包含 speculative 页）；
- `wired`: 不可换出的内核/系统页；
- `compressed`: 压缩器占用页数；
- `throttled`: 被系统节流的页数；
- `swap_used`、`swap_free`、`swap_total`；
- `swap_in_rate`、`swap_out_rate`；
- `compression_growth_rate`。

这里的 `available_estimate` 明确标记为估算值，不伪装成 Apple 内部的唯一压力公式。

### 6.2 进程指标

每个进程至少采集：

- PID；
- 启动时间；
- 父 PID；
- 用户 UID；
- 可执行路径和应用 bundle 标识；
- `phys_footprint`；
- resident size；
- CPU 使用率；
- 线程数；
- 进程状态；
- 可选的脱敏工作目录标签。

列表同时显示 footprint 和 RSS，并在首次使用时提供简短说明：footprint 可能包含压缩和共享映射，RSS 不能代表全部内存影响。

### 6.3 采集 API

生产实现不调用 `top`、`vm_stat` 等外部命令，而使用 macOS 原生接口：

- `host_statistics64`：系统页、压缩器和节流信息；
- `sysctlbyname("hw.memsize")`：总内存；
- `sysctlbyname("vm.swapusage")`：swap；
- `proc_listpids`：进程枚举；
- `proc_pidinfo`：进程基础信息和父子关系；
- `proc_pid_rusage`：进程 footprint/resident 等资源统计；
- `NSRunningApplication`：应用名、图标和 bundle 信息。

不同 macOS 版本可能限制部分路径或命令行信息。采集层必须允许字段缺失，并显示“信息受系统权限限制”；`phys_footprint` 不可用时可暂用 RSS，但必须明确标记为估算值。

## 7. 工作组分组规则

分组优先级从高到低：

1. 明确的自动化 profile、调试端口或工作目录；
2. 应用 bundle 和根进程；
3. 父子进程链；
4. 可执行文件路径和系统框架；
5. 未归属 helper。

首版内置识别器：

- `Codex 自动化`：headless Chrome、临时 profile、调试端口和 Codex 父进程；
- `普通 Chrome`：用户启动的 Chrome 根进程及其 helper；
- `Safari/WebKit`：Safari 根进程和可归属的 WebKit 子进程；无法归属时标为“未归属 WebKit”；
- `MaiBot`：Python 虚拟环境、脚本名和工作目录标签；
- `Ghostty/开发服务`：Ghostty 根进程与其子树；
- `虚拟机`：`Virtualization.framework` 相关进程；
- `Codex 会话`：Codex 根进程及其直接工作子树；
- `通信应用`：微信、QQ 等；
- `系统`：`kernel_task`、`WindowServer`、`ControlCenter` 和系统守护进程。

工作目录标签目前只作为 Node/Python 等通用运行时的细分键；Chrome、Safari/WebKit、Codex 自动化、Ghostty、虚拟机和系统组仍先按各自的高优先级规则归类。

PID 不是稳定身份。内部使用 `(pid, start_time)` 作为进程键，避免旧 PID 被复用后误关联。

## 8. 压力等级与建议引擎

### 8.1 初始等级

以相对比例为主，针对 16 GiB 设备给出初始默认值：

- **正常**：估算可用内存 >= 20%，swap 速率平稳；
- **注意**：估算可用内存 10–20%，或压缩内存持续增长，或 swap 已用 >= 50%；
- **严重**：估算可用内存 < 10%，或 swap 剩余 < 1 GiB，或 swap-in 持续快速增加；
- **采集异常**：无法获得关键指标时单独显示，不伪装为正常。

当前实现采用稳定状态与原始观测分离的防抖策略：首次成功采样立即建立基线，后续升级或恢复必须持续 30 秒才提交；候选异常期间仍保持较快采样，以便及时确认。采集失败时显示“采集受限”，不会把失败样本当作正常或异常状态。

### 8.2 建议排序

建议分数由以下因素组成：

- 用户可操作性；
- footprint；
- 最近增长速度；
- 是否伴随 swap 增长；
- 是否空闲或长期无 CPU 活动；
- 是否属于已知工作组；
- 误操作风险。

系统对象、当前活跃的前台工作组和保护进程必须降权。建议文本必须包含证据，例如：

> Codex 自动化组过去 5 分钟增加约 3.2 GiB，并伴随 swap 增长；建议检查该自动化任务。

首版只给建议，不调用退出或 kill API。

## 9. 技术架构

建议使用 Swift 6、SwiftUI `MenuBarExtra`，必要时用 AppKit 补足菜单栏和窗口行为。核心逻辑放在独立 Swift Package，便于测试。

模块划分：

- `SystemSampler`：系统内存和 swap；
- `ProcessSampler`：进程枚举和资源指标；
- `IdentityResolver`：应用名、图标、父子链和脱敏标签；工作目录只提取安全的项目目录名；
- `WorkloadGrouper`：工作组识别与聚合；
- `PressureEvaluator`：等级、趋势和持续时间；
- `RecommendationEngine`：建议生成与排序；
- `HistoryStore`：本地 24 小时 JSON 磁盘历史；
- `MonitorStore`：面向 UI 的状态快照；
- `MenuBarUI`：菜单栏和 popover；
- `PrivacyFilter`：命令行/路径脱敏和日志过滤。

数据流：

`原生采集 -> 快照标准化 -> 工作组聚合 -> 压力判断 -> 建议生成 -> UI/历史`

并发模型建议使用 Swift Concurrency：采集器由后台 actor 管理，UI 只接收不可变快照，避免在主线程扫描进程。

### 9.1 24 小时磁盘历史契约

- 文件位置：`~/Library/Application Support/MemoryMonitor/history.json`；
- 文件格式：带 `version` 的 JSON envelope，当前版本为 1；
- 采样粒度：采集周期由自适应策略决定（面板打开约 3 秒、面板关闭且压力正常约 20 秒、压力异常约 5 秒），按分钟合并后写盘；首次记录、新分钟和显式 `flush()` 会触发原子写入；
- 保留策略：以当前时间为基准保留最近 24 小时，启动和追加时清理过期记录；
- 持久化字段：时间戳、可用内存比例、压缩内存、Swap 已用量，以及 footprint 最大的 40 个工作组名称、进程数、footprint/RSS 归因总量和系统标记；其余用户组、系统组分别合并为“其他”归因总量；
- 隐私边界：不写入 PID、启动时间、命令行、URL、环境变量、凭据或完整路径；目录权限为 0700，文件权限为 0600。

## 10. 轻量化和稳定性目标

- 后台常驻内存目标：< 40–60 MiB；
- 面板关闭时平均 CPU：< 1%；
- 面板打开时采样间隔：2–3 秒；
- 面板关闭时采样间隔：15–30 秒；
- 压力异常时即使面板关闭也保持约 5 秒采样，恢复正常后自动降频；
- 压力等级变化需连续 30 秒确认，避免瞬时尖峰触发状态切换；
- 只有面板打开或压力异常时才进行更完整的进程细节解析；
- 历史使用版本化 JSON 文件，按分钟合并并默认保留 24 小时，避免引入重型数据库；
- 工作目录身份只保留经过过滤的 basename，用于细分 Node/Python 等通用运行时；无法读取或无法区分项目时回退到通用 runtime 组；
- 采集失败、权限不足或进程消失时优雅降级；
- 监视器必须排除自身的建议对象，避免自我结束或自我放大。

## 11. 隐私与安全边界

- 首版完全本地运行，不联网、不上传遥测；
- 不持久化完整命令行、环境变量、URL、token 或 cookie；
- 日志和历史中的路径只保留应用名、项目目录 basename 或脱敏标签；完整工作目录永不离开采集层；
- 监视面板观察本机所有可枚举进程；未来的操作能力仍只允许当前用户进程；
- 系统进程只读展示，不提供操作入口；
- 任何未来的操作功能都必须重新验证 PID、启动时间、路径、用户和父子关系；
- 未来的强制结束功能必须逐次确认，不能后台自动执行；
- 不使用 `purge` 或删除临时文件作为“优化”手段。

## 12. 测试与验收

### 12.1 采集正确性

- 与活动监视器、`top`、`vm_stat` 的系统总量进行交叉比对；
- 验证 footprint、RSS、压缩内存不会被 UI 混为一个数字；
- 验证 swap 总量动态扩展时仍能正确显示；
- 验证进程退出、重启和 PID 复用不会污染历史。

### 12.2 分组正确性

- Codex headless Chrome 和 Node 能聚合为自动化工作组；
- 普通 Chrome 与自动化 Chrome 能区分；
- MaiBot 多实例能显示父子关系和实例数量；
- WebKit 无法归属时显示未知，而不是错误归属；
- `kernel_task`、`WindowServer` 等始终被标为系统保护对象。

### 12.3 压力场景

- 运行可控的内存分配测试程序；
- 启动和关闭多个 headless Chrome；
- 启动/停止 Python 服务；
- 模拟 swap 增长和进程快速退出；
- 验证等级有持续时间防抖，建议不会重复刷屏。

### 12.4 自身开销

- 空闲 30 分钟的内存和 CPU 采样；
- 面板打开/关闭切换；
- 进程数超过 1000 时的刷新延迟；
- 采集权限受限时的 UI 降级。

## 13. 分阶段实施

### Phase 0：采集校准

交付一个 Swift CLI 或测试 target：

- 输出系统指标和前 20 个 footprint 进程；
- 与现有命令结果对比；
- 固定字段定义和单位；
- 建立合成压力测试。

验收：同一时刻的总内存、压缩内存、swap 趋势与系统工具方向一致，误差有明确解释。

### Phase 1：只读菜单栏 MVP

- 菜单栏常驻状态指示器；
- popover 状态、可用估算、压缩和 swap 指标；
- 按归因总 footprint 排序的全量工作组列表；
- 正常/注意/严重/采集中状态和只读建议；
- 无历史、无操作能力。

验收：应用可构建，面板显示真实系统快照，采样失败时明确显示错误。

### Phase 2：个人工作组与建议

- Codex 自动化、MaiBot、Ghostty、虚拟机识别器；
- 压力等级和趋势；
- 建议引擎；
- 最近 24 小时磁盘历史（分钟粒度）；
- 忽略/稍后提醒规则。

验收：能重现当前已观察的 Chrome/Node/虚拟机场景，并给出正确优先级。

### Phase 3：可选操作能力

此阶段不属于当前首版。设计方向：

- 先请求应用优雅退出；
- 超时后由用户明确确认才允许强制结束；
- 操作前后重新校验进程身份；
- 只允许当前用户、非保护进程；
- 记录操作结果和失败原因。

## 14. 默认个人配置

首版按以下默认值实现：

- 设备：当前 Apple Silicon Mac；
- 监控范围：本机所有可枚举进程；
- UI：菜单栏常驻 + popover；
- 网络：关闭；
- 历史：本地 24 小时；
- 首要工作组：Codex 自动化、Codex 会话、Ghostty/开发服务、MaiBot、浏览器、虚拟机；
- 操作：全部只读；
- 告警：严重状态持续 30 秒后提示一次，恢复后再提示一次；
- 系统对象：可见但默认折叠、不可操作。

待项目初始化后再确认的实现参数：最低 macOS 版本、是否登录时启动、是否使用 App Sandbox、视觉主题细节和历史保留时长。

## 15. 后续项目统一工作顺序

以后开发项目按以下顺序推进，除非明确说明要跳过某一步：

1. **确认环境**：当前目录、项目根、Git 状态、最近的 `AGENTS.md`、运行平台和权限边界；
2. **收集证据**：读取现有代码、配置、锁文件和运行状态，记录真实约束；
3. **明确范围**：写清目标、非目标、风险和需要用户决定的选项；
4. **形成方案文档**：先把架构、数据模型、界面、验收标准和阶段计划落盘；
5. **建立最小骨架**：保持依赖和文件变更最少，先验证关键技术路径；
6. **分阶段实现**：每阶段保持可运行，避免无关重构和生成文件噪音；
7. **逐层验证**：先做窄范围测试，再按风险扩大验证，明确记录未验证部分；
8. **交付说明**：总结改动、验证结果、已知限制和下一步，不隐瞒失败或权限问题。

这份 README 是本项目后续实现的约束基线。任何新增能力都应先更新范围、风险和验收标准，再修改代码。

## 16. Implementation Status

### Phase 0 completed

- Added a native Swift Package with no third-party dependencies.
- Added MemoryMonitorCore system sampling using Mach VM statistics and vm.swapusage.
- Added ProcessSampler using libproc for process identity, parent PID, resident size, physical footprint, and executable path.
- Added memory-monitor-probe for a single read-only snapshot.
- Added unit tests for byte formatting, system sampling, and process enumeration.
- Verified on arm64 macOS 26.5.1 with Swift 6.3.3 and Xcode 26.6.

Run the probe with:

~~~bash
swift run memory-monitor-probe
~~~

The probe deliberately prints executable basenames instead of full command lines. The menu bar UI, pressure evaluation, workload grouping, trend analysis, and disk-backed history are available in the current build.

### Phase 1 completed

- Added `memory-monitor-app`, a SwiftUI `MenuBarExtra` accessory app.
- Added a five-second read-only refresh loop backed by `MemoryMonitorCore`.
- Added pressure classification, system metric tiles, recommendations, and full workload-group rows.
- Kept process display limited to names, PIDs, parents, and memory values; no command lines or control actions.
- Verified with `swift build --product memory-monitor-app`, `swift test`, and a real arm64 CLI probe run.

Launch during development with:

~~~bash
swift run memory-monitor-app
~~~

Process controls remain planned for later phases.

### 本地 App bundle 构建

当前仓库同时提供一个不依赖 Xcode 工程的本地 `.app` 打包脚本。它会构建 `memory-monitor-app`、写入菜单栏应用所需的 `Info.plist`，检查 Apple Silicon 架构，并默认使用 ad-hoc 签名。为避免 iCloud Desktop/File Provider 自动附加 Finder 元数据，默认产物位于本机目录 `~/Library/Application Support/MemoryMonitor/dist/MemoryMonitor.app`：

~~~bash
./scripts/build-app.sh
open "$HOME/Library/Application Support/MemoryMonitor/dist/MemoryMonitor.app"
~~~

也可以通过 `OUTPUT_DIR` 指定其他本机目录；脚本会拒绝 iCloud Drive 或其他 File Provider 路径，因为这些位置可能在签名后重新写入 `com.apple.FinderInfo`。脚本只生成本地产物，不会自动安装、注册登录启动项或修改系统 LaunchAgents。Developer ID 签名、沙盒策略和登录启动开关留到单独阶段决定。

构建脚本支持以下环境变量：`CONFIGURATION=debug|release`、`APP_VERSION`、`BUILD_NUMBER`、`CODE_SIGN_IDENTITY` 和 `SKIP_SIGNING=1`。默认签名身份为本地 ad-hoc（`-`）。

### Phase 2 completed

- Added `WorkloadGrouper` to aggregate each sample into explainable workload groups.
- Current rules cover Codex automation descendants, Chrome, Safari/WebKit, unassigned WebKit, Ghostty/development services, MaiBot, virtual machines, common runtimes, and system processes.
- The popover now shows all sampled process groups, group footprint/RSS attribution totals, process count, and the largest member instead of a flat process-only list.
- Added `WorkloadTrendAnalyzer` to compare consecutive samples and surface the fastest-growing existing group.
- The UI reports a growth recommendation only after a group grows by at least 16 MiB in one sampling interval.
- Added an in-memory `MemoryHistoryBuffer` retaining the latest 60 samples; the covered wall-clock window varies with the adaptive cadence.
- Added `HistoryStore`, a versioned JSON file at `~/Library/Application Support/MemoryMonitor/history.json`.
- History records are coalesced to one record per minute, retain 24 hours, write atomically, and contain only system metrics plus privacy-preserving workload attribution totals. To keep the file lightweight, each record keeps the top 40 workloads and separate user/system aggregates for the remainder.
- The popover now shows available-memory, compression, and Swap changes across the persisted window, and reports history write errors separately from sampling errors.
- Process enumeration retries when the PID list grows during a sample; unavailable physical footprint values are marked as estimates.
- Added adaptive sampling: the panel uses a three-second cadence, normal background monitoring uses twenty seconds, and elevated pressure uses five seconds even when the panel is closed. A visibility change wakes the scheduler immediately.
- Added debounced pressure evaluation: the first successful sample establishes a baseline, and later upgrades or recovery transitions must persist for 30 seconds. Raw elevated observations still request the faster cadence while they are being confirmed.
- Added privacy-preserving working-directory labels for generic Node/Python runtimes. Only a filtered directory basename is retained; common roots such as the home directory, `/tmp`, and `/var/folders` are ignored. A process inherits the first usable label found in its parent chain, and unreadable paths fall back to the previous runtime group.
- Group identity remains heuristic; formal app bundles, login launch behavior, and process controls are still pending.

### Phase 3A completed：本地 App bundle

本阶段只解决可重复构建和本地启动，不扩大监视器的运行权限：

- 目标：从 SwiftPM 产物生成可由 Finder/Launch Services 打开的 `MemoryMonitor.app`；
- 非目标：自动登录启动、系统级安装、Developer ID 发布签名、App Sandbox 和进程操作；
- 架构：`scripts/build-app.sh` 负责构建、在本机临时目录组装并签名，再复制到本机输出目录；同时复制 `Resources/Info.plist`、校验 plist/架构并执行 ad-hoc 签名；
- 风险：ad-hoc 签名只适合本机开发，不能替代 Developer ID 和 notarization；GUI 启动仍依赖当前用户会话；
- 验收：脚本在当前 arm64 Mac 上成功产出 bundle，`plutil` 和 `codesign` 校验通过，`open` 后菜单栏进程可启动，核心测试不回归；File Provider 输出路径会在构建前明确失败并给出本机路径示例。

### 当前限制与下一步

- 工作组识别仍是可解释的名称/父链/目录 basename 启发式；目录不可读、项目目录同名或运行时不属于 Node/Python 时仍可能需要人工区分；
- 已提供本地 `.app` bundle 构建脚本；Developer ID 发布签名、登录启动和沙盒策略仍待单独确定；
- `libproc` 属于 macOS 私有接口，已在本机 arm64 macOS 验证，其他系统版本需要单独回归；
- 退出和强制结束能力仍保持只读边界，后续实现必须只允许当前用户且逐次确认。
