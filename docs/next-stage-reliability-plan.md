# 1.4.2 之后的可靠性实施计划

计划基线：2026-10-22，源码 `dea920aa3145d1033b6d811c768ce07dc9f19ffe`，
版本 1.4.2 (142)。状态：S1 已实施并推送（`e876029`），S2 已实施并推送
（`0dd8acd`、`1c0ccfd`、`cc7b52a`、`18ec7f5`），S3 已实施并推送
（`14a908a`），S2/S3 审查修复已推送（`4f421b3`、`c8d0a42`），S4 已实施
并推送（`f0b2a22`），S5 已实施并推送（`efe799b`、`39c939f`），S6 已实施
并推送（`f869f4d`），S1–S6 复审修复已推送（`13979b6`），S7 证据与发布
记录已推送（`fcf2d91`）；完整原生门禁仍受当前 GUI 会话限制。

建议下一阶段以“可核对来源、可解释中断、可恢复数据”为目标。先完善发布
证据，再补存储检查和审计中断状态，之后实施备份恢复与扫描预算。登录项
目录改名的收益较小，继续保留现有注册路径。

本轮仅分析和编写计划。未启动正式应用，未读取真实历史内容，未修改部署、
清理授权、登录项、TCC 或签名配置。本机只读核对确认部署 bundle 的版本为
1.4.2 (142)，Applications 符号链接仍指向 `releases/1.3.1-final/MemoryMonitor.app`。
真实历史此刻是否已迁移为 v2 未重新读取确认，不能沿用部署时的未迁移状态。

## 现状和证据

上一阶段已经解决确认对象扩大、授权撤销窗口、审计幂等重试、历史满窗写入
放大、bundle 普通失败恢复和 helper CPU 保护。这些机制继续保留。

1.4.2 的 [CI run 39775765559](https://github.com/rongyishuaige7/macos-memory-monitor/actions/runs/39775765559)
已只读复核为 success，对应版本提交 `bbcbaba`；当前 HEAD 后续只更新文档。
此前 328 项非 GUI、7 项隔离原生和 8 项 bundle 恢复检查的完整门禁证据见
[检修记录](review-hardening.md)。1.4.2 部署记录另保留单进程测试的原生状态
污染失败，不能将那次运行表述为 335 项单进程全部通过。本轮未重新运行测试。

下表是源码级观察，复核时应固定上述基线提交；它们不等同于本轮已做故障注入。
所有路径相对仓库根目录，行号以该提交为准。

| Evidence | 来源 | 可复核的观察 |
| --- | --- | --- |
| E01 | `scripts/verify-desktop-integration.sh:123`、`:143`；`Sources/MemoryMonitorApp/DesktopIntegration.swift:182` | 验证脚本传入当前 checkout revision，报告从环境变量读取；随后比较的也是此 revision |
| E02 | `scripts/build-app.sh:149`、`:156`；`scripts/verify-release.sh:48`、`:116` | 构建复制二进制和版本信息，未写构建 revision；门禁退出时删除临时验证目录，却打印目录内的 artifact 路径 |
| E03 | `Sources/MemoryMonitorCore/MemoryMonitorCore.swift:5903`、`:5932`、`:6001`；`scripts/` 文件清单 | v2 索引/分段损坏拒绝 journal 局部覆盖；没有专用的历史检查、完整备份、恢复入口 |
| E04 | `Sources/MemoryMonitorCore/MemoryMonitorCore.swift:5893`、`:5969`；`Sources/MemoryMonitorApp/MemoryMonitorApp.swift:774` | 生产 load 可修剪历史、修补 journal；应用加载后还会 flush，不能拿该路径实现只读检查 |
| E05 | `Sources/MemoryMonitorApp/ProcessActionController.swift:309`、`:1131`、`:1168`、`:1049` | 失败事件按原 ID 保存在内存字典中，在后续操作、刷新和正常 shutdown 重试 |
| E06 | `Sources/MemoryMonitorApp/IntegrationViews.swift:83`；`Sources/MemoryMonitorCore/MemoryMonitorCore.swift:7973` | UI 按事件逐条展示；存储按事件裁剪到最近 7 天、最多 200 条，没有操作级的中断聚合状态 |
| E07 | `Sources/MemoryMonitorApp/SmartCleanupRuntime.swift:213`；`Sources/MemoryMonitorCore/MemoryMonitorCore.swift:1669` | 清理每次扫描全部进程，再逐 root 枚举后代；每次后代枚举各有 1 秒上限，外层没有共享 deadline；detached task 未显式绑定调用方取消 |
| E08 | `Sources/MemoryMonitorCore/MemoryMonitorCore.swift:6771`、`:6787`、`:6815`；`scripts/bundle-replacement.zsh` | 历史采用原子替换并清 journal；bundle 的 trap 可恢复普通中断，但 SIGKILL 无法执行 trap |
| E09 | `Package.swift:8`；`.github/workflows/compatibility.yml:47`；`docs/compatibility-matrix-v1.0.4.md` | 最低系统为 macOS 14，当前托管 CI 仅配置 macOS 15；macOS 14 的历史结果不能代表当前持续验证 |
| E10 | `Sources/MemoryMonitorCore/MemoryMonitorCore.swift:3707`；`Sources/MemoryMonitorApp/MemoryMonitorApp.swift:833` | 已有分层采样和单轮耗时；缺少连续运行的延迟分布、清理扫描开销及生命周期对照报告 |

复核命令均为只读：

```sh
git show dea920a:scripts/verify-desktop-integration.sh
git show dea920a:Sources/MemoryMonitorApp/DesktopIntegration.swift
git show dea920a:Sources/MemoryMonitorApp/ProcessActionController.swift
git show dea920a:Sources/MemoryMonitorApp/SmartCleanupRuntime.swift
git show dea920a:Sources/MemoryMonitorCore/MemoryMonitorCore.swift
gh run view 39775765559 --repo rongyishuaige7/macos-memory-monitor --json status,conclusion,headSha,url
```

## 问题判断与优先级

优先级表示实施顺序，不是漏洞严重性。当前没有新复现的误退出或真实历史丢失。

| Finding | Evidence | 判断及影响 | 优先级 | 实施路径 |
| --- | --- | --- | --- | --- |
| F01 构建来源不足 | E01、E02 | 静态确认：同版本不同源码的 bundle 缺少独立来源证明；环境传参只能证明调用环境，不能证明二进制来源 | P0 | S1 |
| F02 门禁证据无法稳定回看 | E02 | 静态确认：门禁结束后打印的临时 artifact 已被清理，失败细节也可能只留在外层日志 | P0 | S2 |
| F03 历史受保护但恢复操作缺失 | E03、E04 | 静态确认：损坏时保守停写合理，但诊断只给错误文字，人工容易漏掉 segments/clock/journal 或误用 load 改写证据 | P1 | S3、S5 |
| F04 异常退出后的操作结果不明确 | E05、E06 | 内存队列不能跨进程恢复；已有 durable intent 可证明意图，不能证明发送或退出成功。未做本轮跨进程复现 | P1 | S4 |
| F05 扫描工作缺少请求级预算 | E07、E10 | 静态确认结构；用户可见延迟、取消后残余工作量仍需测量。不能据此宣称已经发生 UI 卡死 | P1 | S6 |
| F06 中断与耐久性证据不足 | E08 | 需要进程强退阶段测试；原子重命名不等于已经证明掉电写入顺序。当前不承诺断电零丢失 | P1 | S5、S7 |
| F07 支持范围与验证范围需分开 | E09 | 当前 macOS 14 持续回归缺位；真实登录与公证仍有外部条件 | P2 | S7、外部验收 |

## 设计决策

### 1. 让产物保存自己的构建来源

新增小型 `BuildProvenance` 值类型，bundle 在签名前写入构建清单，包含源码
commit、构建输入摘要、clean/modified、产品版本、架构和工具链版本。
构建输入覆盖 Package.swift、实际 Sources、Resources 和影响构建的脚本；
按有序路径和文件内容计算摘要，不包含用户名、绝对目录、环境变量或凭据。
以后出现 lockfile 或构建配置时同步纳入。

构建前后核对输入未变化；变化则失败，不给变化中的源码标记来源。正式
发布要求输入 clean，开发构建可以显式保留 modified 标记。裸 SwiftPM
二进制没有嵌入信息时返回 unknown；CLI 调用环境可另列为 invocationContext，
不能覆盖 artifact 的来源。bundle 报告优先且仅信任签名覆盖的构建清单。

验收脚本比较“产物来源、期望来源、构建输入摘要”，同时记录可执行文件
SHA-256。文档提交造成 HEAD 不同而构建输入相同时，报告保留真实构建 commit，
另外说明输入等价，不能把旧 bundle 改标成新 commit。此机制用于可追溯性，
不宣称实现了字节级可重复构建或第三方可信证明。

扩展现有兼容性报告时采用可选来源字段并保留旧 JSON 可解码；若必须改变
现有字段语义，升级对应报告 schema，并在同一切片更新生成器和校验器。

### 2. 留下完整且有边界的门禁证据

Release 门禁接受新的绝对输出目录，已有目录拒绝覆盖。默认创建唯一目录，
成功和失败都保留结果、各步骤日志、构建清单、签名校验及兼容性报告；只
清理任务自己的 staging。失败返回非零，清单记录 failed/not_run/skipped，
避免把最后一步未执行当作通过。

原生测试日志作为门禁清单的引用统一收集，记录其独立进程执行方式。输出
目录设为 0700，报告/日志设为 0600；公开 artifact 仅上传经过脱敏的清单。
不自动删除历史证据和恢复备份。产品诊断中仍不收集完整命令行和环境变量。
测试与 workflow 另外计入 verificationInputsDigest，并核对验证期间未变化；
构建输入等价不能替代“这次实际执行了哪些测试”的证据。

### 3. 提供真正只读的存储检查

新增独立 `memory-monitor-storage` 工具，首先仅实现 inspect。它显式接收
存储根和报告位置，复用抽取出的纯解码、边界及 hash 校验，不调用生产
`HistoryStore.load`、`flush`、`merge` 或构造 GUI/清理运行时。
报告写入检查根之外的新文件，拒绝覆盖，避免报告输出本身改变被检查目录。

输出状态使用有限枚举：healthy、legacy、unsupportedVersion、missingIndex、
missingSegment、checksumMismatch、tornJournal、permissionDenied、busy、
changedDuringInspection。报告包含格式、记录数、时间覆盖、文件大小和问题
计数；默认不输出工作组标签、用户绝对路径或历史记录内容。

检查现有锁文件时不创建锁；可安全锁定时读取一致视图，否则用前后 generation
核对并返回 busy/changed，不能把非一致读取报告为 healthy。源目录及文件
内容、权限、mtime 不变是验收项；读取引起的文件系统 atime 不作为内容修改。
应用内进一步展示“磁盘历史受限 / 正在显示内存样本 / 最后成功写入时间”，
给出生成诊断和备份入口，不自动重置。

### 4. 以已落盘事实解释审计中断

增加纯值 `AuditOperationProjection`，按 operationID 聚合。正常进行中的操作
仍显示进行中；上次运行留下且没有 terminal 的操作显示“结果未确认”。只有
intent 时说明可能尚未执行；有 signalSent 时可说明已发出请求，仍不能断言
目标已退出。裁剪后缺少前序事件时显示“记录不完整”，不得补造成功。
投影显式接收当前手动/清理操作 ID 集合，不靠时间猜测是否仍在运行；兼容
旧格式中合法的 terminal-only 记录，不把所有旧记录误标为不完整。

首个切片复用现有事件格式及隐私边界，不持久化 PID、路径或进程身份，不
新增自动重放进程操作的能力。失败事实继续用原 event ID 重试，增加有上限
的退避调度和待写数量；队列达到上限时暂停接受新的进程动作，允许取消、
查看和重试，避免无限积压。UI 区分执行结果与审计是否落盘。
该门槛同时约束手动操作和清理批次中的后续目标，已经发出的请求继续核验；
不得为了释放队列空间丢弃未落盘的已发送事实。

不把“再加同盘 outbox”当作磁盘不可写的完整解法。信号发送和日志写入无法
做跨内核/文件系统原子事务；重启后没有证据的事实永远保持未知。首个切片
不改变 7 天/200 事件保留策略，以免同时引入迁移和保留语义变化；操作级保留
如确有需求，单独设计。正常 shutdown 的重试不替代异常退出测试。

### 5. 用完整备份恢复已知状态

在 inspect 和构建来源完成后增加 backup/restore。备份保存 history 索引、
其引用的 segments、journal、clock，以及 audit 文件和 clock；清单记录
缺失状态、hash、格式和构建来源。锁文件是协调对象，不作为可恢复的数据
内容。清理授权和登录项注册不随备份自动恢复或重新批准。
损坏集合也可原样备份取证，但清单必须标记不可用于直接恢复；恢复只接受
完整且通过校验的集合。输出拒绝已有目录、符号链接逃逸和源数据子目录，
避免覆盖备份或把备份递归包含进自身。

首版要求应用已退出且协调锁可取得；现有进程检查和 store 锁不足以阻止新
应用在多文件恢复间隙启动，因此 S5 先引入共同 maintenance 锁，所有生产
store 操作先取 maintenance 共享锁，恢复取独占锁，再按 history → audit
顺序取现有 store 锁；锁文件 inode 不随数据替换。已持独占锁的维护路径
不再嵌套获取共享锁，避免自锁。活跃后台任务无法排空或锁不全时拒绝操作。
旧二进制不认识新 maintenance 协议，因此仍要求正式实例退出并全程持有旧
store 锁；跨进程并发和锁顺序须先验证，再开放 restore。

先在新的目标卷内目录复制、验证并输出不可变备份，再处理恢复；恢复前
保留当前完整集合，以事务标记记录阶段和每个重命名。由于实际数据根还
可能包含 dist/releases/backup 等应用目录，不能重命名整个 Application
Support 根；只替换清单列明的数据文件集合，在 maintenance 锁内完成，
启动时发现未完成事务则阻止正常写入并提示恢复。取消或失败保留两份副本。

v1 备份恢复到 v2 曾使用的目录时，当前 segments 必须随当前集合一起移入
恢复副本，避免混合两代数据。索引丢失时不能从所有孤立分段猜测权威版本；
只能恢复经过校验的完整备份。首版不提供拼接部分分段或一键丢弃损坏历史。
旧版本回滚必须匹配数据格式，不能只替换 app。

### 6. 限制扫描成本并保持退出保护

为清理的一次 ActivityInventory 引入共享 monotonic deadline、总成员上限和
扫描 generation；所有 root 的枚举共用预算。首先记录扫描数、成员数、完整性、
耗时和取消延迟。初始目标为一次扫描 1.5 秒预算，为现有 2 秒退出新鲜度检查
预留余量；此值是设计目标，需在 S6 基准后校准，不能放宽最终 2 秒保护。

显式保存 detached worker handle，取消沿调用链传递到 PID/父子枚举循环。
同一清理运行时最多一个实际 worker 在运行；取消后旧 worker 未排空前不能
继续创建新 worker。同步内核调用无法强行抢占，过期结果丢弃并继续阻止动作，
不能用 timeout 后遗留无限后台任务的方式制造“及时完成”。

复用一次请求内已确认的后代结果，减少同一 helper 被多个 root 重复遍历；
不直接复用普通监控的旧样本用于退出判断。AppKit 句柄、前台和授权检查
继续留在 MainActor；耗时解析使用不可变值在后台完成，最后仍同步核对。
任何超时、成员变化、取消、generation 不匹配或不可读成员都得到 unknown，
不能变成 CPU=0 或候选可退出。

## 分阶段交付

每个切片完成针对性验证、文档记录、独立 commit 和 push 后再进入下一片。
预计工作量是单人专注开发的粗估，不含人工登录、外部设备和签名资质等待。

| 顺序 | 最小交付及主要影响面 | 依赖 | 验收重点 | 估计 |
| --- | --- | --- | --- | --- |
| S1 | 构建清单、BuildProvenance、桌面报告与版本来源校验；build-app / DesktopIntegration / CompatibilityReport | 当前基线 | 同版本旧源码包被识别；环境伪造无效；构建中输入变化失败；旧报告仍可读 | 1–1.5 天 |
| S2 | Release 门禁证据目录和步骤清单；verify-release / verify-native-tests | S1 | 成功、失败均留下有效路径；拒绝覆盖；各项 source/digest 一致；失败退出码不被吞 | 0.5–1 天 |
| S3 | storage inspect、纯校验复用、结构化历史健康状态；Core / 新 CLI / 设置页 | S1 | v1/v2/损坏/权限/并发变化分类；只读前后 hash/mtime/权限一致；不生成产品文件 | 1–2 天 |
| S4 | 操作级审计视图、待写队列边界和有界重试；ProcessActionController / IntegrationViews | S2 | 重建 controller 后正确显示未知；从不重发动作；保留 event ID；新动作门闩、互斥和取消不回归 | 1–2 天 |
| S5 | maintenance 锁、完整 backup/restore、事务恢复和数据故障注入；Core / storage CLI | S3 | 并发写入被阻止；v1/v2 双向集合替换；各阶段强退后可恢复；备份不被覆盖 | 3–5 天 |
| S6 | 清理扫描共享预算、取消传递、局部复用与连续性能报告；Runtime / ProcessSampler | S4 | deadline 共用、旧结果无效、任务数有界；忙碌 helper 及最终门闩全部保留 | 1–2 天 |
| S7 | 组合验收、升级/回滚演练、发布记录与支持矩阵 | S1–S6 | 使用保留证据的完整 gate；在临时数据上完成升级/回滚；人工项单独记录 | 0.5–1 天 |

合计约 **8–14.5 个工作日**。S4 与 S3 在代码上可独立解释，但按单代理顺序交付。
阶段依赖路径：F01/E01 → S1 构建来源 → S2 证据留存 → S4 审计恢复 → S6 成本；
F03/E03 → S3 只读检查 → S5 完整恢复；两条路径在 S7 汇合。

版本建议：修补来源/证据后如需独立部署，可按 patch 发布；包含存储工具、
恢复入口和操作级审计的整阶段候选为 1.5.0，实际 bump 在发布切片决定。
设计文档不修改版本号，不把中间代码提交视作已经部署。

## 验收矩阵与停止条件

| 领域 | 必须验证的场景 | 完成标准 |
| --- | --- | --- |
| 来源 | 同版本不同 commit、dirty 输入、缺清单、环境变量冒充、仅文档变化 | 未知或不匹配明确返回；报告不会改写产物自己的来源 |
| 历史检查 | 空目录、v1、v2、索引缺失、分段损坏/丢失、torn journal、未知版本、符号链接、超大文件 | 分类准确且无源内容/权限/mtime 变化；忙碌不假报健康 |
| 审计 | intent 后中断、已发送后终态丢失、重复事件、队列满、存储持续失败、200 事件裁剪 | 无虚假成功、无自动重发、内存有界，已有事实可重试 |
| 恢复 | 索引提交前后、journal 清空前后、恢复各次 rename 前后、磁盘满、权限失败、并发启动 | 保留可恢复副本；事务未决时拒绝写入；不混合 v1/v2 集合 |
| 扫描 | 大进程族、重叠 root、取消、睡眠/唤醒后过期、成员替换、未知父链、持续高 CPU | 无 stale 样本触发退出；共享预算有效；真实 worker 数有界 |
| 产品回归 | 关闭窗口后台采样、打开面板、压力模式、历史 24h 断档、减少动态效果 | 既有刷新和安全契约保持；数据未知不显示为正常 |
| 发布 | 非 GUI 测试、四套独立原生测试、严格并发 Debug/Release、probe、签名、CI、fixture 启动 | 各项实际通过，revision/digest 可关联；未执行项明确保留 |

数据故障测试使用新临时根和任务自己创建的子进程，在明确 checkpoint 后强退，
重新实例化 store/CLI 校验。历史不仅检查可解码，还核对分钟集合、24h 边界、
hash、journal 合并和旧副本保留。普通错误注入与进程强退分开记录。断电需要
额外耐久性设计和环境验证，不能由 SIGKILL 测试代替。

性能报告使用同一构建输入、同机相近负载，覆盖后台 10 分钟、窗口可见
5 分钟、连续取消扫描及合成大进程族；记录样本数、p50/p95/max、CPU、RSS、
逻辑写入字节和扫描次数。现有安全阈值是硬条件；后台 CPU/RSS 先建立基线，
不预先声称节省百分比。只有可重复超出基线 20% 才触发进一步性能调查，
该数值是调查阈值，不是现有性能承诺。

任一切片出现误目标、未知状态被视作空闲、索引被局部覆盖、备份混合、
恢复中仍有写入、门禁吞错或来源被覆盖，停止其依赖切片并修复。默认完整
release gate 的非 GUI/独立 GUI 入口继续使用；单进程 swift test 的 AppKit
状态污染单独跟踪，不能静默跳过新增原生测试。

## 需要真实环境的后续验收

| 项目 | 当前决策 | 进入条件与证据 |
| --- | --- | --- |
| 登录项路径迁移 | 延后；现有注册 URL 继续使用 | 只有存在实际路径管理收益才单独迁移；先备份与恢复准备，再由用户完成可能出现的批准 |
| 真实登录启动 | 单独人工窗口执行 | 固定签名和路径；记录注销前后 boot/session、实际 bundle 来源和启动结果；自动状态查询不能替代 |
| macOS 14 桌面与回归 | 保留最低版本，明确当期验证缺口 | 可用自托管/真实设备后复用门禁；同时纠正文档中“已退役”与未来退役日期的混用，不猜测 runner 可用性 |
| Developer ID / notarization | 外部分发阶段实施 | 身份和发布目标明确后准备 hardened runtime、签名、公证与 Gatekeeper 验证；不在本地可靠性阶段新增凭据 |

不以统一底层信号、自动关闭更多应用、扩展到磁盘/网络完整监控、替换 JSON
为数据库或拆分全部 8,000 行 Core 作为本阶段目标。新增纯校验和来源模块可
独立成文件，但只抽取本阶段需要的边界，避免同时扩大数据迁移和安全回归面。

## 首个实施切片

从 **S1 构建来源** 开始：先用临时同版本旧清单固定现有校验缺口，再实现
签名前的构建清单与报告读取，补齐来源拒绝用例和严格构建。该切片通过并
推送后进入 S2。任何正式部署均需使用可核对的候选产物和完整数据恢复准备；
本计划不自动执行登录项迁移或真实用户会话操作。

## S1 实施记录（2026-10-22）

状态：已完成并推送，源码 `e876029`；未部署、未修改 1.4.2 已安装 bundle。

- 新增 `BuildProvenance`（Core）：schema、源码 revision、clean/modified、
  有序构建输入摘要、产品版本/构建号、架构、工具链版本；缺失/非法/未知
  checkout state 一律返回 nil，不猜测来源。
- `scripts/build-provenance.zsh` 统一计算 revision、checkout state 和构建
  输入摘要；输入按相对路径 + 内容排序，不含用户名、绝对路径、环境变量或
  时间戳。`build-app.sh` 在签名前写入
  `Contents/Resources/BuildProvenance.json`，构建前后摘要不一致则失败。
- 桌面集成报告 `DesktopIntegrationReport.current` 只读签名 bundle 内的
  provenance；环境变量不再参与来源字段。缺失清单时报告
  `sourceRevision=nil`、`checkoutState=unknown`、`provenanceSource=unknown`。
- `CompatibilityProductReport` 增加可选 `buildInputsDigest` /
  `provenanceSource`；旧 JSON 仍可解码。裸 SwiftPM probe 将环境来源标为
  `provenanceSource=invocation`，不能冒充 bundle 来源；collector 校验该
  invocation digest 与当前构建输入一致。
- `verify-desktop-integration.sh` 校验产物 provenance、当前输入摘要、
  clean 状态和报告中的 bundle 来源；仅文档变化导致 HEAD 不同而输入摘要
  一致时保留产物真实 revision 并报告输入等价。
- `verify-release.sh` 校验生成 bundle 的 provenance 版本/构建号/clean/
  digest 后才继续发布门禁。
- 验证：`swift test` **341 项全部通过**；Debug/Release 严格并发构建通过；
  干净提交构建的 bundle provenance 为 `e876029` / clean；环境变量伪造
  `deadbeef` 被拒绝；桌面报告 `provenanceSource=bundle`；兼容性报告为
  `invocation` 且 digest 与当前输入一致；CI
  [run 39783266878](https://github.com/rongyishuaige7/macos-memory-monitor/actions/runs/39783266878)
  通过，产物为 1.4.2 (142)。
- 未做：旧 bundle 部署替换、真实登录/公证；S1 的构建来源机制尚未进入已
  安装 bundle。下一步为 S2 门禁证据留存。

## S2 实施记录（2026-10-22）

状态：已完成并推送；源码 `18ec7f5`。未修改已安装 1.4.2 bundle。

- `verify-release.sh` 接受新的绝对证据目录；已有目录/符号链接拒绝覆盖，
  默认使用唯一临时目录并保留。证据目录 0700，manifest/日志 0600。
- 每个步骤独立日志：`git_checks`、`bundle_replacement`、`non_gui_tests`、
  `native_tests`、Debug/Release build、probe、compatibility、build_app、
  validate_app、desktop_report、verification_inputs_stable。
- `manifest.json` 记录 status/exitCode、started/finished、源码 revision、
  checkout state、build inputs digest、verification inputs digest、产物
  相对路径和每个步骤的 passed/failed/skipped；失败步骤记录退出码。
- 构建/验证输入摘要前后核对；变化时失败。构建产物 provenance、签名、
  版本、desktop report 和兼容性报告均在证据目录保留。
- 原生测试使用独立进程；显式
  `VERIFY_RELEASE_SKIP_NATIVE_TESTS=1` 时记录为 `skipped`，不冒充 passed。
  默认仍运行原生门禁；本机当前 AppKit inactive 偶发失败已记录在失败证据中。
- 成功证据：`/private/tmp/mm-s2-success`（native_tests=skipped；其余 passed）。
- 失败证据：`/private/tmp/mm-s2-failure`（native_tests 失败；日志和 manifest
  保留）。已有目录覆盖测试返回 2 且 manifest 不变。
- 门禁不会自动删除历史证据或恢复备份；只清理 build-app 自己的 staging。
- CI [run 39786753536](https://github.com/rongyishuaige7/macos-memory-monitor/actions/runs/39786753536)
  通过（源码 `18ec7f5`）。
- 未做：S3 只读历史检查、S4 审计中断聚合、S5 完整备份/恢复、S6 扫描预算、
  S7 升级/回滚验收。

## S3 实施记录（2026-10-22）

状态：已完成并推送；源码 `14a908a`。未修改已安装 1.4.2 bundle。

- 新增 `HistoryInspection`（Core）：独立只读解析 v1 index、v2 index +
  15 分钟分段、journal、clock sidecar；不调用 `HistoryStore.load/flush/
  merge`，不创建锁、不修复 journal、不修剪历史。
- 分类：`healthy`、`legacy`、`empty`、`unsupportedVersion`、`missingIndex`、
  `missingSegment`、`checksumMismatch`、`tornJournal`、`permissionDenied`、
  `busy`、`changedDuringInspection`、`unsafePath`、`invalidData`、
  `fileTooLarge`。报告包含格式、记录数、分段数、journal 数、时间覆盖、
  文件字节数和问题计数；不含路径、workload 标签或历史内容。
- 检查前后对 index/segments/journal/clock 做 inode/size/mtime 指纹核对；
  现有锁文件只读打开并尝试共享锁，绝不创建锁；busy 时直接返回。
- 新增独立可执行 `memory-monitor-storage inspect --root ... --output ...`；
  输出必须绝对路径、位于检查根之外且不存在；报告 0600；不覆盖已有报告。
- 应用健康页在历史错误时显示“磁盘历史受限 / 正在显示内存中的 N 个样本 /
  最后成功写入时间”；`HistoryStoreDiagnostics` 新增
  `lastSuccessfulWriteAt`，只在真实 snapshot/journal 写入成功后更新。
- 测试：`HistoryInspectionTests` 11 项通过；全量 `swift test` 352 项中
  351 项通过，唯一失败仍是 `CleanupMotionTests` 的无前台 AppKit 状态；
  Release 严格并发构建通过。
- 真实存储只读检查：`legacyV1`，1 条记录，报告 0600，检查前后
  `history.json`/journal 哈希一致；报告位于 `/private/tmp/mm-s3-report.json`。
- CI [run 39790073109](https://github.com/rongyishuaige7/macos-memory-monitor/actions/runs/39790073109)
  通过（源码 `14a908a`）。
- 未做：S4 审计中断聚合、S5 完整备份/恢复、S6 扫描预算、S7 升级/回滚；
  真实登录、公证和部署仍未变更。

## S2/S3 审查修复记录（2026-10-22）

- 门禁步骤改为每个命令显式 `|| return 1`，不再依赖被 `if` 条件抑制的
  `set -e`。故障注入 `git diff --check` 后，`git_checks` 记录为 failed，
  后续步骤不再执行，manifest 退出码为 1。
- `memory-monitor-storage` 在判断报告位置前解析根和输出父目录的真实路径；
  通过祖先符号链接把报告写进检查根会返回 2，且不创建文件。
- 历史检查器在 v2 索引存在时验证 segments 目录必须是真实目录；目录缺失、
  符号链接或非目录均不再报告 healthy。
- 索引和全部分段共享 `maximumSnapshotFileBytes` 预算，超过后标记
  `fileTooLarge`，不再只限制单段大小。
- manifest 写入失败不再被 `|| true` 吞掉；成功门禁会转为非零退出。
- `SWIFT_TEST_FLAGS` 禁止 `--filter`/`--skip`/`--only-testing`；新增
  `non_gui_test_scope` 步骤，要求实际执行至少 300 项非 GUI 测试。
- 构建输入发现符号链接时拒绝生成摘要；`Package.swift`、Sources、Resources
  及验证输入均覆盖。
- 验证：`swift test` **354 项全部通过**；Release 严格并发构建通过；
  `HistoryInspectionTests` 13 项通过；S2 成功证据
  `/private/tmp/mm-s2-final2`；失败注入证据
  `/private/tmp/mm-s2-stepfail2`；CI job `39801787180` 的 macOS 15 任务
  成功（run 级记录仍显示 in_progress）。

## S4 实施记录（2026-10-22）

状态：已完成并推送；源码 `f0b2a22`。未修改已安装 1.4.2 bundle。

- 新增 `AuditOperationProjection`：按 `operationID` 聚合 intent/signalSent/
  terminal；进行中的操作显示“进行中”，上次运行留下且无 terminal 的显示
  “仅确认/已发送，结果未确认”，缺少前序事件显示“记录不完整”。
  terminal-only 旧记录识别为合法终态，不误标不完整；不补造成功。
- `ProcessActionController` 暴露 `activeAuditOperationIDs`，手动和 Smart
  Cleanup 的活跃操作显式参与投影；terminal 后清理，超时保留到强制结束/
  取消。
- 待写审计队列上限 64；队列满时只阻止新的手动动作，已发出的 signalSent/
  terminal 事实不丢弃。失败事件保留原 event ID，按 2→60 秒指数退避重试；
  Smart Cleanup intent 审计失败继续 fail closed。
- 审计面板增加“操作/事件”视图、待写入数量和队列满提示；事件视图保留
  原有筛选/搜索。
- 验证：`swift test` **365 项全部通过**；Release 严格并发构建通过；
  CI job `39807793660` 的 macOS 15 任务成功。
- 未做：S5 完整备份/恢复、S6 扫描预算、S7 升级/回滚；真实登录、公证和
  部署仍未变更。

## S5 实施记录（2026-10-22）

状态：已完成并推送；源码 `efe799b`（maintenance 锁 + 完整备份）与
`39c939f`（事务恢复 + recover）。未修改已安装 1.4.2 bundle。

- 新增 `.maintenance.lock`：生产 `HistoryStore`/`ProcessActionAuditStore`
  的每次操作先取共享锁；备份取独占锁并再取 history/audit 共享 store 锁；
  恢复取独占锁后按 history → audit 顺序取独占 store 锁。锁文件独立于数据
  文件，不随数据替换。
- 新增 `memory-monitor-storage backup`：要求应用退出，输出拒绝已存在目录、
  根内路径和符号链接逃逸；保存 history 索引/全部分段/journal/clock 与
  audit/clock；清单记录缺失状态、hash、大小、角色、格式、历史状态和可选
  `BuildProvenance`。损坏集合可原样备份但 `restorable=false`。
- 新增 `restore`：校验 `backup.json`、每个文件 hash、路径和审计文件；
  先把当前集合完整复制到事务目录，再把备份复制到 staging；写事务标记后
  才替换目标数据，v1/v2 集合整体替换，不混合 segments。
- 新增 `recover`：按事务标记回滚到恢复前集合；`committed` 阶段只清理；
  未完成标记会阻止 HistoryStore/AuditStore 正常操作并提示先运行 recover。
- 验证：非 GUI `swift test` **373 项通过**；`StorageBackupTests` 6 项、
  `StorageRestoreTests` 5 项、`MaintenanceLockTests` 4 项通过；Release
  严格并发构建通过；CI job `39812051896` 的 macOS 15 任务成功。
- 真实数据：`/private/tmp/mm-s5-backup-final` 备份成功（legacy，5 个文件）；
  在临时根恢复并逐文件 hash 一致，未对真实数据执行 restore。
- 未完成/边界：未做每个 rename 阶段的强退注入矩阵；未做应用内备份/恢复
  按钮；未对真实数据执行恢复；S6 扫描预算、S7 升级/回滚仍待实施。

## S6 实施记录（2026-10-22）

状态：已完成并推送；源码 `f869f4d`。未修改已安装 1.4.2 bundle。

- 新增 `ProcessScanBudget`：1.5 秒 monotonic deadline、总成员上限 20,000；
  `sampleDetailed` 和 `descendantProcessIDs` 在每个 PID/父子枚举循环检查
  取消、deadline 和成员上限。
- `LiveSmartCleanupRuntime` 的每次 ActivityInventory 共享同一预算；所有
  root 的后代枚举共用剩余成员预算。扫描失败/超时/成员超限/取消时
  `metrics.complete=false`，不产出候选退出对象。
- 清理扫描最多一个 detached worker；新扫描先取消并等待旧 worker，旧结果
  通过 generation 丢弃。worker 显式保存并响应调用方取消。
- 同一请求内按 root 缓存已确认后代集合，减少重叠 root 的重复枚举；不把
  普通监控旧样本用于退出判断。
- `CleanupInventoryMetrics` 记录 generation、扫描次数、成员数、完整性、
  耗时、取消延迟和预算耗尽；清理 UI 显示扫描指标。
- 验证：非 GUI `swift test` **376 项通过**；`ProcessScanBudgetTests` 3 项
  通过；Release 严格并发构建通过；CI job `39816072143` 的 macOS 15 任务
  成功。
- 未完成/边界：未做合成大进程族、连续取消和真实 1.5 秒预算基准；原生
  AppKit 套件仍有环境相关偶发失败；S7 升级/回滚验收仍待实施。

## S1–S6 复审修复记录（2026-10-23）

- P1 恢复并发：`recover` 先取 maintenance 独占锁和 history/audit 锁，再在锁内
  读取事务标记；标记已消失时幂等 no-op。回滚前验证 current backup 是真实
  目录；两个并发 CLI recover 均返回成功，历史和审计保持为恢复前副本。
- P1 审计校验：备份新增 JSONL 纯内容校验（逐行解码、大小/换行检查）；
  损坏审计备份 `restorable=false`，恢复再次校验。合法缺失审计不再拒绝
  恢复，恢复按备份集合移除当前审计。
- P2 智能清理准入：`recordExternalAudit` 的 intent 在待写队列满时返回失败，
  与手动操作共用准入限制；已发送/terminal 事实仍保留。
- P2 扫描 worker：等待旧 worker 后重新检查 generation；只有最新请求可创建
  新 worker。新增阻塞扫描 fixture，3 个并发请求最大 worker 数为 1。
- P2 投影：terminal-only 只有 `operationID == event.id` 才识别为旧格式；
  新操作被裁剪后标记“记录不完整”，不再显示旧格式。
- 验证：非 GUI `swift test` **383 项通过**；针对性 57 项通过；Release
  严格并发构建通过；真实备份/临时恢复 hash 一致；CI job `39900320424`
  的 macOS 15 任务成功。
- 未完成：完整 GUI/原生门禁未重跑；S7 升级/回滚和部署仍待实施。

## S7 证据记录（2026-10-23）

状态：S7 证据切片已完成并推送；源码 `fcf2d91`。完整原生门禁未全绿，
发布记录见 [release-readiness-s1-s7.md](release-readiness-s1-s7.md)。

- 修复 fixture 对新增 `.maintenance.lock` 的兼容校验；fixture 可重新生成
  v2 数据（240 历史、239 journal、12 审计、1 分段）。
- 完成 v2 → v1 → v2 临时数据升级/回滚演练：最终 `healthy/segmentedV2`，
  无 v1/v2 混合；未对真实数据执行 restore。
- 当前 HEAD 完整 `verify-release.sh`：非 GUI 383 项通过；原生
  `CleanupMotionTests` 2、`DesktopWindowTests` 3、`SmartCleanupNativeTests`
  1 通过；`DesktopMotionTests` 因当前会话无法激活窗口失败。失败证据保留在
  `/private/tmp/mm-s7-gate-full`。
- 显式跳过原生的完整 artifact 门禁通过：`/private/tmp/mm-s7-gate-skip`，
  `native_tests=skipped`；未把它当作完整原生通过。
- CI [run 39911542300](https://github.com/rongyishuaige7/macos-memory-monitor/actions/runs/39911542300)
  的 macOS 15 arm64 任务成功。
- 支持矩阵、人工项和停止条件已写入发布记录；未 bump 版本、未部署。
