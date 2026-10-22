# Memory Monitor

个人 macOS 内存进程监视器设计与实施方案。

- 目标设备：当前这台 Apple Silicon Mac
- 物理内存基线：16 GiB
- 首版形态：菜单栏常驻 + 点击弹出详细面板
- 首版范围（历史基线）：只监视、分析和给出建议，不执行进程退出或强制结束
- 当前 App bundle：v1.4.1（build 141）；独立桌面窗口 + 菜单栏快捷面板
- 当前本地 App bundle 使用 Apple Development 签名；Developer ID、notarization 和沙盒策略尚未启用
- 文档状态：设计基线，可作为后续实现的验收依据

## 当前桌面版（v1.4.1）

主窗口提供内存概览、进程管理、释放内存、24 小时历史、压力测试和设置。
菜单栏保留快速查看及页面入口；设置和进程详情归主窗口管理，避免菜单栏
失焦时连带消失。支持深浅外观、进程搜索与内存/CPU 排序。

概览采用更清晰的仪表、四项核心读数与轻量玻璃层次。进程按已有应用归因
分组，展开后可查看单个成员；释放页提供智能清理、授权名单与本次记录。
历史根据已有记录选择初始范围，超过两分钟的记录断档保持断开。
统计页展示所选时段的最近值、平均值和最高值，曲线标注平均线与峰值；
鼠标悬停在图中可查看原始记录的时间和使用率，断档不补造数据。
设置提供深浅预览及动效开关；数字短过渡和局部粒子遵循减少动态效果设置。
智能清理的扫描弧、曲线粒子流、退出反馈与核验动画由 Core Animation
驱动，窗口隐藏、最小化、失焦或粒子区域滚出视口时停止。内存压力升高
时减少清理粒子，严重或状态未知时停止；不添加整窗背景动画。

首次进入释放页，在清理名单中勾选可以随时退出的应用，随后可一键执行。
默认不授权任何应用；前台、两分钟内使用/离开前台/首次观察的应用和检测
到忙碌的应用会被跳过。每次最多处理八个应用，逐个请求正常退出，允许
应用保存或拒绝；可跳过等待或停止后续操作，不自动强制结束或清理子进程。
结果分别显示已退出应用和多次采样得到的可用内存变化，不承诺固定收益。
CPU 检查合计可识别的后代进程和同 bundle 内 helper；成员变化、枚举失败或成员
不可读时保守跳过。独立枚举父子关系，避免无关系统进程的权限限制阻断所有应用。
外部服务、磁盘/网络工作等仍不能完整识别，名单中仅应加入愿意退出的应用。
清理包含本软件自己的 malloc 可回收内存整理，不删除缓存文件或人为制造
内存压力。手动进程操作仍保留在进程页；它与智能清理、压力测试互斥。
UI fixture 模式禁用智能清理执行，避免演示数据触发真实应用退出。压力测试分为
128/256/512 MB，最长 30 秒，支持停止和自动释放；内存紧张时拒绝启动。
历史范围为 1/6/24 小时，与现有本地保留期限一致。

应用标识采用 M 字母与开口监测环，已用于 Dock、侧栏、设置页及菜单栏
关闭百分比后的图标模式。[Logo 预览](Resources/Brand/Logo-Preview.png)、
[透明 PNG](Resources/Brand/Logo.png)、[SVG](Resources/Brand/Logo.svg) 和
[macOS 图标](Resources/MemoryMonitor.icns) 均在仓库中。

架构与验收记录见 [桌面版重构](docs/desktop-interface-v1.1.0.md)、
[1.2.0 界面优化](docs/visual-refinement-v1.2.0.md)、
[1.2.1 应用标识](docs/brand-identity-v1.2.1.md)、
[1.3.0 智能清理](docs/smart-cleanup-v1.3.0.md) 和
[1.3.1 统计图优化](docs/history-chart-v1.3.1.md)。v1.4.0 稳定化与 1.4.1
安全补丁的范围、
风险、分阶段验收和剩余限制见
[stabilization-v1.4.0.md](docs/stabilization-v1.4.0.md)。以下章节保留
早期设计与历次实现背景，当前界面以上述文档为准。

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

`内存 78%`

状态颜色和图标只表达等级：

- 正常：中性颜色；
- 注意：琥珀色；
- 严重：红色；
- 采集受限：灰色并标注原因。

点击后打开 360–440 px 宽的 popover。采样频率会随面板可见性和压力状态调整：面板打开时加快，面板关闭且压力正常时降频，压力异常时保持较快观察；历史按分钟写盘。

### 5.2 弹出面板布局

1. **当前状态条**
   - 压力等级用圆点和颜色表达；
   - CPU、内存、GPU 已使用百分比；
   - 指标暂不可用时显示 `--`，不使用猜测值。

2. **进程列表**
   - 默认显示单进程排行，按 footprint 降序，RSS 和 PID 作为稳定次序；
   - 每行显示进程名、PID、用户/系统标识、footprint 和 RSS；
   - 可切换到工作组归因排行，组内数值为 footprint/RSS 归因总量。

3. **事件时间线**
   - 记录压力等级变化、工作组启动/退出、swap 越过阈值和建议生成；
   - 只保留本地 24 小时磁盘历史；历史数据在后台写盘，当前紧凑面板不展开趋势卡片。

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
- `compression_growth_rate`；
- `cpu_used_fraction`：相邻 Mach CPU 累计计数的使用比例（按整机总量）；
- `gpu_used_fraction`：IOAccelerator 提供的 `Device Utilization %`，没有驱动数据时为空。

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
- `host_statistics(HOST_CPU_LOAD_INFO)`：整机 CPU 累计计数；
- `sysctlbyname("hw.memsize")`：总内存；
- `sysctlbyname("vm.swapusage")`：swap；
- `proc_listpids`：进程枚举；
- `proc_pidinfo`：进程基础信息和父子关系；
- `proc_pid_rusage`：进程 footprint/resident 等资源统计；
- `IORegistryEntryCreateCFProperties`（`IOAccelerator`）：Apple Silicon GPU 使用率；
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
- `ProcessActionRuntime`：隔离进程采样、信号发送和时间控制；生产实现将 libproc 读取放到 utility 任务，测试可注入假运行时。

数据流：

`原生采集 -> 快照标准化 -> 工作组聚合 -> 压力判断 -> 建议生成 -> UI/历史`

并发模型建议使用 Swift Concurrency：采集器由后台 actor 管理，UI 只接收不可变快照，避免在主线程扫描进程。

### 9.1 24 小时磁盘历史契约

- 文件位置：`~/Library/Application Support/MemoryMonitor/history.json`；
- 文件格式：v2 JSON 索引，数据位于 `history.json.segments/` 下的 15 分钟分段，增量仍使用 `history.json.journal`；可读取 v1 快照，首次写入/修剪时迁移，旧版应用拒绝 v2 历史，降级前需另行导出或备份；
- 采样粒度：采集周期由自适应策略决定（面板打开约 3 秒、面板关闭且压力正常约 20 秒、压力异常约 5 秒），按分钟合并后写盘；首次记录、新分钟和显式 `flush()` 会触发原子写入；
- 保留策略：以当前时间为基准保留最近 24 小时，启动和追加时清理过期记录；
- 满窗后只改写变化的边界分段，原子切换索引后删除旧分段，逐条裁剪过期记录；分段经过 SHA-256 校验，损坏时报告错误，不以局部 journal 覆盖完整历史；
- 备份/恢复历史需一起处理索引、`.segments`、`.journal` 和 `.clock`；单独丢失索引会报告读取失败，保留分段供修复；
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
- 进程刷新覆盖率仅排除内核明确返回 `EPERM/EACCES` 的不可读条目；退出、身份变化和未知失败仍纳入 50% 门槛。诊断同时保留原始覆盖率、权限拒绝数量及可读条目覆盖率；历史完整性仍要求所有枚举进程均可读；
- 监视器必须排除自身的建议对象，避免自我结束或自我放大。

## 11. 隐私与安全边界

- 首版完全本地运行，不联网、不上传遥测；
- 不持久化完整命令行、环境变量、URL、token 或 cookie；
- 日志和历史中的路径只保留应用名、项目目录 basename 或脱敏标签；完整工作目录永不离开采集层；
- 监视面板观察本机所有可枚举进程；操作能力只允许当前用户的非系统进程；
- 系统进程只读展示，不提供操作入口；
- 每次操作都重新验证 PID、启动时间、路径、用户和父 PID；任一信息缺失或变化都会拒绝；
- 优雅退出和强制结束都必须逐次确认；强制结束还要求同一进程的优雅退出先超时，不能后台自动执行；
- 操作结果只写入本地受限审计日志，不保存 PID、启动时间、命令行或完整路径；
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

### 12.5 进程操作可靠性

- 使用假运行时验证优雅退出成功、超时、取消、身份变化、父进程/路径变化、PID 复用、信号失败和审计写入失败；测试不得向真实第三方进程发送信号。
- 验证等待截止时间使用单调时钟，系统墙上时间调整不会改变超时窗口。
- 验证用户确认意图必须先成功写入审计；意图写入失败时不会采样或发送信号，并通过“记录受限”提示暴露；发送后的终态写入失败不会改变已执行的信号结果。
- 验证旧快照或错误进程触发强制结束请求时，不会覆盖原目标的超时状态。
- 验证发送边界发生身份替换时拒绝操作，且无法取得 audit token 时强制结束保持 fail-closed。

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
- 操作：当前用户的非系统进程可逐次请求优雅退出；优雅退出超时后可二次确认强制结束；工作组不支持批量操作；
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

Process controls are guarded and limited to the current user's non-system processes; see Phase 7 below.

### 本地 App bundle 构建

当前仓库同时提供一个不依赖 Xcode 工程的本地 `.app` 打包脚本。它会构建 `memory-monitor-app`、写入菜单栏应用所需的 `Info.plist`，检查 Apple Silicon 架构，并默认使用 ad-hoc 签名。为避免 iCloud Desktop/File Provider 自动附加 Finder 元数据，默认产物位于本机目录 `~/Library/Application Support/MemoryMonitor/dist/MemoryMonitor.app`：

~~~bash
./scripts/build-app.sh
open "$HOME/Library/Application Support/MemoryMonitor/dist/MemoryMonitor.app"
~~~

应用以菜单栏代理（`LSUIElement=true`）启动；打开主窗口时切换到常规激活策略并显示 Dock 图标，关闭窗口后菜单栏继续监视。点击菜单栏中的 `内存 xx%` 状态项打开快捷面板；设置和进程详情归主窗口管理，避免菜单栏失焦时连带消失。

也可以通过 `OUTPUT_DIR` 指定其他本机目录；脚本会拒绝 iCloud Drive 或其他 File Provider 路径，因为这些位置可能在签名后重新写入 `com.apple.FinderInfo`。脚本只生成本地产物，不会自动安装、注册登录启动项或修改系统 LaunchAgents。Developer ID 签名、沙盒策略和登录启动开关留到单独阶段决定。

重复构建会先在输出卷复制并验证候选 bundle，再重命名替换；普通失败或可捕获的中断会恢复旧 bundle。成功后旧 bundle 保留在输出目录的隐藏 `.MemoryMonitor.app.replacement.*/previous.app` 中，路径会打印到日志。并发构建会被目录锁拒绝；若断电或 `SIGKILL` 留下 `.MemoryMonitor.app.replacement-lock`，先按其中 `transaction-path` 核对候选、旧 bundle 与目标，再手动恢复并移除锁。脚本不会清理这些恢复备份。

原生桌面回归使用 `./scripts/verify-native-tests.sh [新的绝对日志目录]`，需要当前用户的登录桌面，会显示测试窗口并仅退出专用 fixture 应用。四个套件分别运行，覆盖窗口、动效生命周期及 AppKit 正常退出/拒绝退出；失败保留日志并返回非零，不修改登录项或 TCC。`verify-release.sh` 会先运行逻辑测试，再调用此入口；托管 CI 继续只运行非 GUI 测试。

构建脚本默认从 [`Resources/Info.plist`](Resources/Info.plist) 读取 `1.4.1 / 141`，也支持以下环境变量覆盖：`CONFIGURATION=debug|release`、`APP_VERSION`、`BUILD_NUMBER`、`CODE_SIGN_IDENTITY` 和 `SKIP_SIGNING=1`。默认签名身份为本地 ad-hoc（`-`）。发布基线和验收要求见 [`docs/release-readiness-v1.0.3.md`](docs/release-readiness-v1.0.3.md)。

### Phase 2 completed

- Added `WorkloadGrouper` to aggregate each sample into explainable workload groups.
- Current rules cover Codex automation descendants, Chrome, Safari/WebKit, unassigned WebKit, Ghostty/development services, MaiBot, virtual machines, common runtimes, and system processes.
- The popover now shows all sampled process groups, group footprint/RSS attribution totals, process count, and the largest member instead of a flat process-only list.
- Added `WorkloadTrendAnalyzer` to compare consecutive samples and surface the fastest-growing existing group.
- The UI reports a growth recommendation only after a group grows by at least 16 MiB in one sampling interval.
- Added an in-memory `MemoryHistoryBuffer` retaining the latest 60 samples; the covered wall-clock window varies with the adaptive cadence.
- Added `HistoryStore`, a versioned JSON file at `~/Library/Application Support/MemoryMonitor/history.json`.
- History records are coalesced to one record per minute, retain 24 hours, write atomically, and contain only system metrics plus privacy-preserving workload attribution totals. To keep the file lightweight, each record keeps the top 40 workloads and separate user/system aggregates for the remainder.
- 历史记录仍在后台持续写盘；紧凑面板不再展开历史趋势卡片或建议文字。
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

### Phase 3B completed：进程占用排行

- 面板默认显示“进程排行”，保留本次采样的全量进程快照；每行显示排名、进程名、PID、footprint 和 RSS。
- 进程按 footprint 从大到小排序，footprint 相同时按 RSS 和 PID 稳定排序，便于直接定位当前最大的进程。
- “工作组归因”保留为可切换视图，同样按归因 footprint 从大到小排列；列表使用固定高度滚动区域，避免内容被 SwiftUI 菜单栏面板压缩成不可见。
- 进程与工作组数值仍是归因口径，包含共享映射；不能把各行相加当作整机实际占用。

### Phase 3C completed：核心利用率与紧凑面板

- 面板指标收敛为 CPU、内存、GPU 已使用百分比；删除可用估算、压缩、Swap 卡片，压力等级继续通过状态圆点与黄/红色表达。建议在 Phase 4B 以单条只读建议卡呈现。
- CPU 使用率由 Mach 累计计数的相邻采样差计算；GPU 优先读取 Apple Silicon `IOAccelerator` 的 `Device Utilization %`，驱动不提供时显示 `--`。
- 24 小时历史仍按分钟持久化，作为后台数据能力保留，不在当前紧凑面板展开。

### Phase 3D completed：可信度与归因解释

- 将系统内存、CPU、GPU、进程枚举拆成独立采样源；单个源失败时，其余指标继续更新，不把失败结果写成 0。
- 新增 `SampleQuality`/`SampleStatus`：每个源明确标记实时、部分可用、暂无数据或采集失败，并保留实际采样时间和可计算的 sample age。
- 内存使用百分比继续采用 `1 - (free + inactive + purgeable) / total` 的压力感知估算，因此界面和探针会标注“估算”；它不是 footprint 总和，也不等同于 `memory_pressure` 的 free percentage。
- 进程扫描报告枚举数、成功采样数和跳过数；`phys_footprint` 不可读时以 RSS 估算，并把整次进程结果标为部分可用。
- 进程快照增加可选应用名称和 bundle identifier（仅从本地 `.app` 元数据解析）；工作组增加归因依据和代表进程父链摘要。未找到 Safari 父链的 WebKit 明确显示“未找到 Safari 父链”，不再暗示异常归属。
- 对重复/复用 PID、父链循环、计数器溢出和稳定排序增加防护；公开快照解码兼容旧字段并再次执行标签清理。
- 新增可注入采样协调器，覆盖部分失败降级、无效系统数据、GPU 缺失和排序等测试；核心测试当前共 56 项。
- 当前机器校准显示：`memory_pressure` 的 free percentage 与本项目的可回收内存估算口径不同，`top` 的 PhysMem 也不能与进程 footprint 行简单加总；这些差异属于指标定义，不是采集错误。

### Phase 4A/4B completed：分层采样与只读建议

- 采样模式分为后台、后台进程刷新、面板打开和压力异常；系统指标保持连续观察，正常后台约 20 秒采样、进程约 60 秒刷新，压力状态约 5 秒采样、进程约 10 秒刷新，避免面板关闭时每轮都扫描全部进程。
- 每轮快照记录采样模式、总耗时、进程扫描耗时和是否执行进程扫描；未执行的进程扫描不会覆盖上一轮成功数据。
- 建议引擎只消费不可变快照和上一轮对照数据，输出单条最高优先级建议、证据、置信度和预期影响；建议永远不调用退出或 kill API，并使用已防抖的压力等级避免瞬时尖峰误报。
- 建议必须考虑采样质量：进程列表部分可用或系统指标估算时降低置信度，无法支撑结论时只提示数据受限。
- 建议去重以稳定的规则 ID 和目标工作组 ID 为键，不因每轮数值微小变化重复制造新提示。
- CLI probe 现在同时输出采样模式、总耗时、进程扫描耗时和首条只读建议，便于不打开 GUI 时核对采样质量。
- 本版验收重点已完成：正常后台降低进程扫描频率；面板/压力状态仍能及时刷新；增长、压力和 Swap 组合能给出可解释建议；采样失败和数据不足不产生误导性清理建议。

### Phase 5 completed：24 小时趋势与事件时间线

- 面板新增“实时 / 24 小时”切换；实时视图保持现有进程和工作组排行，历史视图使用本地分钟记录，不触发额外进程扫描。
- 历史页分别展示内存使用率和 Swap 已用量曲线，并给出当前值、窗口峰值、样本数量和覆盖时长；超过 240 个点时只在绘图层降采样，磁盘原始记录不变。
- `MemoryHistoryAnalyzer` 是纯函数式分析器，从已持久化的脱敏记录推导压力切换、Swap 阈值跨越、工作组进入/离开保存排行和显著增长事件；事件按时间、严重度稳定排序并限制数量。
- 工作组事件明确表示“进入/离开历史排行”，不把 Top 40 压缩变化误报为进程启动或退出；跨越过大的历史间隔不会推断工作组生命周期。
- 工作组事件只连接完整且时间可信的 workload 观测：marker 必须接近所属分钟记录，相邻记录与 marker 都需严格递增且间隔不超过 5 分钟；旧文件中的异常 marker 会被跳过而不影响其他历史指标。
- 历史页在无记录、写盘失败和数据不足时分别降级显示，不清空实时监视数据；事件分析不写入 PID、命令行或完整路径。
- 新增历史摘要、阈值事件、工作组变化和重复 ID 容错测试；核心测试当前共 56 项。

### 当前限制与下一步

- 工作组识别仍是可解释的名称/父链/目录 basename 启发式；目录不可读、项目目录同名或运行时不属于 Node/Python 时仍可能需要人工区分；
- 已提供本地 `.app` bundle 构建脚本；Developer ID 发布签名、登录启动和沙盒策略仍待单独确定；
- `libproc` 属于 macOS 私有接口，已在本机 macOS 26 和 GitHub 托管的 macOS 14/15 arm64 环境完成只读采样；真实桌面、不同权限和精确最低次版本仍需单独回归；
- 事件时间线基于分钟记录推导，不能替代进程生命周期审计；过期或被压缩出 Top 排行的工作组可能只显示为排行变化；
- 进程信号优先绑定 audit token，并在取 token 后再次校验 `(PID, 启动时间, 用户, 父 PID, 可执行路径)`；无法取得 token 时，优雅退出可在最终复核后降级，强制结束会拒绝发送，因此仅降级的优雅退出仍保留固有 TOCTOU 窗口；
- 进程操作的等待窗口已使用单调时钟，但 macOS 仍可能在信号发送后短暂延迟回收 PID；界面会保守地等待下一次身份采样，不把权限受限误报为已退出；
- 当前不提供工作组批量操作、自动清理、自动重启或系统进程控制；
- 登录启动、Developer ID/notarization 和 App Sandbox 仍未启用，计划在后续发布与权限策略阶段单独评估；

### Phase 6 completed：轻量历史写盘与详情面板（v0.7.0）

- 24 小时历史保留兼容的 `history.json` 快照，并新增 `history.json.journal` 追加日志；分钟记录先追加到 journal，达到 120 条或 1 MiB 后再压缩回快照，降低高频整文件重写带来的写盘放大。
- 启动时会合并快照和 journal；如果进程在最后一行写入中退出，只截断不完整尾行并保留之前的有效记录；仅有 journal、缺少快照时也可以恢复。
- 历史文件和 journal 继续使用本地 `Application Support/MemoryMonitor` 目录，目录权限为 `0700`，文件权限为 `0600`；`HistoryStoreDiagnostics` 可观察快照/journal 大小、待写记录和压缩次数。
- 实时进程排行支持名称、应用、Bundle ID 和脱敏工作目录搜索，支持全部/用户/系统筛选，并可按 footprint 或 RSS 降序排列；工作组排行使用同一套排序和成员搜索规则。
- 工作组和历史 Top 排名会先展示精确 footprint，再展示 RSS 估算值；不同口径不再仅按数值大小混排，增长趋势也沿用同一质量优先规则。
- 点击进程可查看 footprint、RSS、虚拟内存、累计 CPU 时间、线程数、启动时间、应用身份、父进程链和当前工作组；点击工作组可查看归因依据、置信说明、成员明细、最近 24 小时 footprint/RSS 趋势及相关事件。
- 详情只展示脱敏标签和汇总值，不写入 PID/启动时间到历史；进程或工作组离开当前快照时会明确标记为不可见，不把它误判为已退出。
- 本阶段的实时监视与详情能力保持无副作用；进程操作在下一阶段单独加入并受独立安全策略约束。
- 本版核心测试共 60 项，Release App target 构建通过；后续每个小版本继续执行测试、Release 构建、本机部署、提交并推送。

### Phase 7 completed：受保护的进程操作（v0.8.0）

- 进程详情页提供“请求优雅退出”，当前通过 audit-token 绑定的 `SIGTERM` 发送；无法取得 token 时仅允许在最终身份复核后降级。
- 优雅退出等待约 8 秒后只显示强制结束入口，不自动升级；强制结束必须再次确认，并且只有取得 audit token 后才发送绑定目标身份的 `SIGKILL`。
- 操作范围限制为当前登录用户、非 UID 0、非系统标记、非保护名称/系统路径，且排除 Memory Monitor 自身；系统进程、其他用户进程、身份不完整进程只显示拒绝原因。
- 每次发送信号前重新采样并校验 PID、启动时间（含微秒范围）、UID、父 PID 和规范化可执行路径；生产 runtime 在取得 audit token 后执行最后一次校验，强制结束继续绑定优雅退出开始时的原始快照，发现变化即拒绝。
- 强制结束不会因为 PID 复用而命中新进程；等待阶段按 `(PID, 启动时间)` 区分原进程与复用 PID，超时和失败都不会自动重试。
- 操作结果写入 `~/Library/Application Support/MemoryMonitor/actions.jsonl`，目录/文件权限分别为 `0700/0600`，默认保留 7 天最多 200 条；日志对 PID、路径和控制字符做脱敏，并能恢复不完整尾行。
- 工作组详情明确不提供批量结束；所有操作必须在单个进程详情中逐次确认。每次操作先写入“已确认”意图，再记录“已发送”和最终结果，并以关联 ID 串起阶段；意图写入失败会阻止本次信号，失败事件保留原 ID 并在后续操作或退出时重试，审计发布失败只显示“记录受限”。
- 核心测试当前共 70 项；已通过 `swift test` 和 `swift build --product memory-monitor-app`，并继续执行 Release 构建、探针、本机部署和 Git 推送验收。

### Phase 8 completed：进程操作可靠性与可测试性（v0.9.0）

- 将采样、进程存在性检查、优雅/强制信号发送和等待时钟抽象为 `ProcessActionRuntime`；生产实现为 `LiveProcessActionRuntime`，单个进程的 libproc 读取在 utility 任务中执行，避免操作准备阶段阻塞菜单栏界面。
- 超时判断改用 `mach_continuous_time()` 的单调连续纳秒值，墙上时间只用于显示截止时间；手动改时钟、NTP 校时或系统睡眠唤醒不会把等待窗口误判为已到期。
- 控制器在意图审计成功后才进入采样和信号边界；终态仍先发布再写审计，审计目录不可写、磁盘写入失败或写入较慢时不会让界面永久处于忙碌状态；失败通过独立的“记录受限”状态暴露。
- 详情页增加取消当前操作入口，并区分尚未确认发信号、已发送优雅退出请求和强制结束校验中的取消语义；取消不会自动升级为强制结束。
- 目标离开最新进程列表后，详情页仍保留“停止跟踪”入口，但不会在缺少当前快照时提供新的退出或强制结束动作。
- 过期或错误进程调用强制结束接口时保留原目标的超时状态，不因陈旧 UI 行覆盖可执行的二次确认上下文；强制结束仍绑定优雅退出开始时的原始 `(PID, 启动时间)` 快照。
- 新增 `MemoryMonitorAppTests`，以假采样、假信号和可控时钟覆盖 10 个控制器场景；核心 70 项加应用控制器 10 项，共 80 项测试，验证过程不触碰真实第三方进程。
- 本版已通过 `swift test --parallel`（80 项）、严格并发 Release 构建、签名校验、Release 探针和本机替换部署；提交并推送按每个小版本的交付流程完成。

### Phase 9 completed：系统集成与运行自检（v1.0.0）

本阶段把“应用是否正在可靠工作”本身变成可观察对象，并提供明确的系统集成开关。

- `LoginLaunchCoordinator` 封装 `SMAppService.mainApp`，登录启动默认关闭，只有用户在设置面板明确打开后才注册；`requiresApproval`、注册失败和应用尚未位于可注册位置都显示为可解释状态，不伪装成成功。
- 登录项操作失败会保留在健康状态中，直到下一次操作成功或系统状态在外部设置中确实发生变化，避免错误提示卡死也避免被被动刷新误清除。
- 新增运行健康快照，分别报告系统/CPU/GPU/进程采样、24 小时历史、操作审计和登录启动状态；“正常”“部分可用”“需要处理”分级，权限受限与采样失败不再混成一个错误。
- 设置/诊断面板提供一键重新检查，并可跳转 macOS 登录项和隐私设置；应用不会自行修改系统权限，也不会要求不必要的 Full Disk Access。
- 新增只读操作审计总览，支持按结果筛选、时间倒序查看和受限记录提示；不提供清空、批量结束或自动修复动作。
- 使用假登录启动运行时和构造快照覆盖状态映射、注册/注销失败、健康等级、审计筛选及历史/采样降级；不在测试中改动真实登录项或系统设置。

验收：`swift test --parallel` 覆盖新增状态机；Release App bundle 能显示版本和登录启动状态；在本机明确关闭登录启动时，应用持续运行且设置面板能解释当前状态；登录启动开关只在用户确认后改变系统注册状态。

实际验收（2026-08-27）：

- `swift test --parallel`：87/87 通过（包含登录启动、健康等级、采样性能和审计筛选测试）。
- `swift build --configuration debug -Xswiftc -strict-concurrency=complete` 和 `swift build --configuration release -Xswiftc -strict-concurrency=complete`：通过。
- `./scripts/build-app.sh`：成功生成 arm64 `MemoryMonitor.app`；`CFBundleShortVersionString=1.0.0`、`CFBundleVersion=10`，`codesign --verify --deep --strict` 通过，且已链接 `ServiceManagement.framework`。
- Release probe：系统总内存 16.0 GiB，进程采样 481/728（部分进程受 macOS 权限限制），未归属 WebKit 归因总量约 13.6 GiB；受限状态按设计显示为部分可用。
- 本机部署：`/Users/rongyi/Applications/MemoryMonitor.app` 以 `open -g` 启动并稳定运行；登录启动保持关闭，未修改真实登录项或系统设置。

### Phase 10 completed：可靠性加固（v1.0.1）

- 采样失败、空结果和低覆盖率结果不会清空最近一次可用的进程/工作组快照；诊断会保留失败原因并按策略重试。
- 系统、进程、GPU、历史和审计数据增加有限值、时间戳、长度、控制字符及整数溢出校验，避免坏数据触发崩溃或污染建议。
- 历史快照与 journal 分层恢复，损坏尾部可截断并继续读取；重复 workload 标识、重复时间戳和大规模聚合采用确定性处理。
- 进程操作状态机增加取消、超时、token 和目标身份校验，过期异步任务不能覆盖新状态。
- 设计与验证记录见 [`docs/reliability-hardening-v1.0.1.md`](docs/reliability-hardening-v1.0.1.md)。

当前实现已通过核心与应用测试、Debug/Release 严格并发构建、Release probe 和 app bundle 签名验证；本阶段未自动提交或推送 Git 改动。

### Phase 11 completed：v1.0.3e 状态收口验收（2026-08-28）

- freshness marker 只用于时间可信且完整的 workload 观测；写入/合并拒绝远离所属分钟桶的 marker，历史分析跳过旧文件中的异常 marker，并拒绝跨越过大的记录间隔。
- `swift test --parallel`：223/223 通过；新增 marker 相对偏差、记录间隔和亚秒观测回归测试。
- `swift build --configuration debug -Xswiftc -strict-concurrency=complete` 和 `swift build --configuration release -Xswiftc -strict-concurrency=complete`：通过。
- Release `memory-monitor-probe`：成功完成本机只读采样，进程覆盖率受系统权限限制时明确显示为部分可用。
- `scripts/build-app.sh`：成功生成 arm64 Release `MemoryMonitor.app`；`CFBundleShortVersionString=1.0.3`、`CFBundleVersion=13`，ad-hoc 签名及 `codesign --verify --deep --strict` 通过。

### Phase 12 completed：v1.0.4a 兼容性诊断

- 运行健康面板新增“运行环境”条目，显示当前 macOS 版本、进程架构和发布支持级别。
- macOS 低于 14.0 标记为需要处理；非 arm64 仅标记为部分可用，不宣称绝对不兼容。
- 环境信息只在内存中参与诊断，不写入历史或操作审计；跨版本实机回归仍需在对应系统上单独执行。
- 设计和验收标准见 [`docs/compatibility-diagnostics-v1.0.4.md`](docs/compatibility-diagnostics-v1.0.4.md)。

### Phase 13 completed：v1.0.4b 结构化兼容性报告

- `memory-monitor-probe --compatibility-json` 输出带 schema 版本的脱敏 JSON，只包含产品、平台、采集源质量、耗时和进程覆盖率，不包含 PID、进程名、路径、用户或设备标识。
- `scripts/collect-compatibility-report.sh` 注入 `Info.plist` 版本、Git revision 和源码状态，校验结构后把 JSON 写到标准输出；脚本不修改登录项、系统权限或进程状态。
- 发布验收脚本现在同时验证人类可读 probe 和结构化报告，并要求 arm64、完整进程扫描及三项明确的未执行限制。
- 当时的干净源码基线 `30571b8` 在 arm64 macOS 26.5.1 的一次采样中读取 406/636 个进程；系统、CPU、GPU 数据有效，权限受限条目仍按部分可用呈现。后续桌面集成证据见 Phase 15。
- 当前矩阵和缺失环境见 [`docs/compatibility-matrix-v1.0.4.md`](docs/compatibility-matrix-v1.0.4.md)。

### Phase 14 completed：v1.0.4c1/c2 自动兼容性矩阵

- 新增 `scripts/verify-compatibility.sh`，要求显式输出路径和预期平台，运行 228 项测试、Debug/Release 严格并发构建、Release probe 与结构化采集，并校验只读限制项。
- GitHub Actions 使用 arm64 `macos-14`/`macos-15` runner，分别固定 Xcode 16.2 / Swift 6.0.3 和 Xcode 16.4 / Swift 6.1.2；仓库权限仅为 `contents: read`，脱敏报告 artifact 保留 14 天。
- [run 33254292547](https://github.com/rongyishuaige7/macos-memory-monitor/actions/runs/33254292547) 两个 job 均通过：macOS 14.8.7 采样 `205/402`，macOS 15.7.7 采样 `261/490`；系统与 CPU 数据可用，托管虚拟环境没有可读 GPU 利用率。
- 矩阵运行推动修复了 Swift 6.0/6.1 的 Optional 匹配、actor 文件锁隔离、同步闭包隔离和旧 Darwin SDK 导入差异；本机 Swift 6.3.3 回归保持通过。
- 本阶段不验证真实 GUI 会话中的登录项、TCC 权限切换或 audit-token 发信号；这些工作保留给 v1.0.4c3，并只允许使用专用测试进程。

### Phase 15 completed：v1.0.4c3b 桌面集成诊断（2026-08-29）

- 新增严格参数路由的桌面诊断入口：`--desktop-integration-json` 只读采集登录项状态和进程覆盖率；未知参数在构造 GUI 之前以非零状态退出。
- 新增显式双重 opt-in 的专用子进程 audit-token 检查。检查器固定创建 `/bin/sleep` 子进程，只通过生产 `sendForce` 发送绑定的 `SIGKILL`，并在成功或失败后回收子进程；普通 `swift test` 不触发真实信号。
- `swift test --parallel`：233/233 通过；Debug/Release 严格并发构建、`scripts/verify-release.sh`、arm64 App bundle 签名和桌面诊断结构校验均完成。桌面验证脚本的整体退出码因登录项 `not_found` 保持为 `1`，报告已保留供人工步骤复核。
- 本机 c3b bundle 在 macOS 26.5.1 arm64 上生成 schema 1 报告，源码 revision 为 `bb57ff6fa04af48d253751b56cde4f3e1d40d175`、checkout 为 `clean`；进程采样 `424/671`（63.19%），质量为 `estimated` 且可用。
- 只读基线的 audit-token 为 `not_run`；显式专用子进程报告为 `passed`，目标和信号分别固定为 `dedicated_child` / `SIGKILL`。两份报告的 `SMAppService.mainApp` 状态均为 `not_found`。
- `scripts/verify-desktop-integration.sh` 对当前登录项状态按设计返回非零并保留 `0600` 报告；这表示登录项服务尚未被当前 bundle 注册或发现，不是被隐藏的“通过”。本阶段未执行登录项注册/系统批准、重新登录自动启动或 TCC 权限前后对照，也未修改系统状态。
- 详细边界、原始报告位置和待人工步骤见 [`docs/desktop-integration-validation-v1.0.4.md`](docs/desktop-integration-validation-v1.0.4.md)；本机证据已同步到 [`docs/compatibility-matrix-v1.0.4.md`](docs/compatibility-matrix-v1.0.4.md)。
