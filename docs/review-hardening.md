# Review hardening after 1.4.1

## Scope

修复只读审查复现的清理确认范围、授权撤销、审计重试与终态一致性问题，
优化满 24 小时历史的持久化成本，并使构建产物替换具有失败恢复能力。
随后完善采样覆盖诊断、后台忙碌保护和原生测试入口。

## Non-goals

不迁移登录项、不注销用户会话、不修改真实历史/授权数据，不改变进程信号
原语，不启用新的签名或公证流程，不增加依赖或进行无关模块重构。
本系列交付源码和验证产物，不自动替换已部署的 1.4.1。

## Architecture

- 清理 UI 先刷新两次活动样本，再冻结最多八个应用的确认集合；执行入口
  必须显式接收该集合，重新扫描只能减少目标，不能增加目标或替换身份。
- intent 写入后再次检查取消和授权；保留运行时同步的前台/活动/身份保护。
- intent 写入失败阻止退出；已发请求和终态写入失败进入原事件 ID 的重试
  队列。已验证退出的成功终态推迟至批次最终核验，避免先成功后重启的漂移。
- 历史采用 v2 索引加 15 分钟不可变分段，仍读 v1 快照和原 JSONL journal。
  压缩复用内容未变的分段，仅改写新增/过期边界；逐条裁剪保留窗口，不扩大
  24 小时期限。每个分段以 SHA-256 校验并限制大小/数量和路径。
  先写分段，原子切换索引，再清空 journal 和删除旧分段；进程在中途停止时
  保留旧索引或可合并的重复 journal。复用跨实例 flock、时钟锚和失败重试。
  v2 索引包含空 records 字段，让旧版本明确拒绝 version=2，避免误恢复覆盖。
  升级只在真实写入/修剪时发生，本轮仅验证临时数据，未迁移真实历史。
  每个 encoder/decoder 复用 Sendable 的 ISO8601FormatStyle 值，避免逐日期
  构造非 Sendable formatter。
- bundle 先在目标卷完成复制和签名验证，再可恢复地替换；失败保留旧产物。
- 进程扫描保留每个失败的原因和可读取的 BSD 身份元数据；仅明确的权限拒绝
  可从刷新覆盖率分母排除，消失、身份变化及未知失败仍计入。原始覆盖率及
  不完整标记继续用于诊断与历史，不因此扩大清理/进程操作权限。
- 清理 CPU 检查聚合主进程、后代及同 bundle 内 helper；成员变化、CPU 回退
  或无法确认完整性时不给出空闲判断。最终同步门闩仍检查样本新鲜度。
  使用独立 PROC_PPID_ONLY 枚举（有数量/时间上限），在 BSD 元数据受权限
  限制时仍识别实际后代；只要目标族成员不可读或未包含在 CPU 扫描中便跳过。
  bundle 外且不在父链中的服务，以及 I/O 工作，仍不承诺完整识别。
- 原生桌面入口先检查当前控制台用户及 GUI 会话，然后将四个 XCTest 套件
  分别运行在独立进程中；严格核对七项执行计数，保留逐套件日志及源码状态，
  不自动更改 TCC/登录项。Release 门禁先跑非 GUI，再调用独立原生入口。

## Risks

确认与执行之间应用可能退出、更新、变忙或撤销授权，均应跳过；不能用重新
挑选应用填补名额。取消不能撤回已发送请求，仍须记录最终已知事实。
历史与 bundle 的文件操作必须在临时目录注入故障验证，避免破坏现有数据。

## Verification

- 为已复现的五个行为缺口加入正式回归用例，补充确认身份替换、取消窗口、
  最终测量失败和审计恢复边界。
- 受影响逻辑测试、完整 Swift 测试、Debug/Release 严格并发构建及
  `git diff --check`；原生 GUI 测试单独记录环境限制。
- 满窗历史验证压缩次数、持久化字节、重新加载、保留期和并发实例一致性。
- bundle 替换使用临时 bundle 验证成功、复制失败、验证失败和回滚。

## Staged delivery

1. 清理确认与审计闭环；验证后独立提交并推送。
2. 历史持久化与编解码优化；验证后独立提交并推送。
3. bundle 替换与失败恢复；验证后独立提交并推送。
4. 采样诊断/忙碌保护与原生验证入口；完成相关门禁并提交推送。

## Results

### 1. 清理确认与审计闭环

- 49 项清理/进程操作针对性测试通过；完整非 GUI 测试 314 项通过。
- 覆盖确认后新增应用、身份替换、去重与八个上限、intent 等待期间撤销和
  取消、最终重启、测量失败，以及已发请求事实的幂等审计重试。
- `git diff --check` 通过；原生 GUI 和严格并发构建在最终门禁统一运行。

### 2. 分段历史与日期编解码

- 完整非 GUI 测试 319 项通过，包含 v1 迁移失败重试、分段/索引损坏、
  journal 局部恢复拒绝、路径约束、跨实例与时钟回拨等已有回归。
- 合成 1441 分钟 × 40 个工作组的物理快照为 10,029,842 bytes；滚动三分钟
  快照写入共 257,298 bytes，相比同规模三次全量重写减少约 99.1%。这是逻辑
  写入量，不等于设备物理写入量或稳定耗时基准。磁盘分段逐条检查了保留期。
- fixture 工具通过生产 store 回读校验 240 条历史与 12 条审计；启动器同步
  校验分段目录和文件权限。无真实用户数据迁移。
- 补充索引丢失保护，阻止只从近期 journal 重建而丢弃旧分段；195 项核心
  测试通过。重置/备份契约同步说明需要一起处理分段及 sidecar。

### 3. 可恢复 bundle 替换

- 输出卷内先复制和验证候选，再保留 previous.app 并重命名安装；普通失败
  和可捕获中断恢复旧 bundle。成功也保留旧 bundle，未自动清理备份。
- 8 个隔离用例通过：成功、复制/候选验证/安装/最终验证失败、备份后中断、
  符号链接拒绝及已有锁保留。Release/兼容性脚本已纳入这些用例。
- SIGKILL/断电不能触发 shell trap；目录锁和 transaction-path 保留恢复位置，
  后续构建拒绝覆盖，需按 README 核对恢复。
- 临时输出目录连续两次真实 Release 构建/替换成功，当前与 previous.app
  均通过 `codesign --verify --deep --strict`（ad-hoc）；未替换部署 bundle。

### 4a. 权限与扫描失败分离

- 321 项非 GUI 测试通过，覆盖 errno 分类、重复/已采样 PID 不得计入权限
  拒绝、可读覆盖率门槛及 MonitorSampler 到兼容性报告的字段传递。
- 保留原始 coverageFraction，新增可选 permissionDeniedCount 和
  readableCoverageFraction。旧报告可缺少这些字段；未放宽历史完整性条件。

### 4b. 应用进程族活动保护

- 33 项针对性测试通过，包括六个 CPU 聚合回归、真实子进程枚举、清理
  状态机及 AppKit 正常退出/拒绝退出用例。未注入替代运行时绕过原生检查。
- 覆盖孙进程、launchd 托管的同 bundle helper、成员增减/PID 复用、计数
  回退、未知/过期窗口、实际不可读成员与无关系统权限拒绝的区别。
- 单进程全量 335 项运行中，桌面粒子套件因 inactive 出现四个断言失败；
  其余用例通过。最终原生入口将隔离套件运行，消除 AppKit 状态跨套件污染。

### 4c. 原生入口与最终门禁

- `verify-native-tests.sh` 四个隔离套件共 7 项通过；再次使用已有日志目录
  返回 2，原日志保留。无需更改 TCC、登录项或真实用户数据。
- `scripts/verify-release.sh` 完整通过：328 项非 GUI + 7 项原生，8 项 bundle
  故障/恢复检查，Debug/Release 严格并发构建（无编译告警），Release probe、
  结构化兼容性报告、arm64 bundle 默认版本和严格签名验证。
- 本机环境 macOS 26.5.1 arm64；probe 观测 695/941 进程。该结果只代表本机
  当前权限环境，不外推 macOS 14/15 的真实桌面或会话登录行为。
- `launch-ui-check.sh` 端到端通过：240 条历史、12 条审计、239 条 journal
  增量，经 Launch Services 启动独立签名 fixture bundle，隔离环境检查通过；
  随后核对精确可执行路径并正常终止该任务创建的进程。保留临时 bundle。
- 已部署 1.4.1、登录项路径/批准状态及真实用户历史均未改动；未做真实注销/
  登录验证，未启用 Developer ID/notarization，仍保留 AppKit 正常退出语义。

### 4d. 最终代码的 CI 证据

- [Compatibility run 39750430970](https://github.com/rongyishuaige7/macos-memory-monitor/actions/runs/39750430970)
  于 2026-10-22 成功，验证源码为
  `ac46a15a461ef5ff03e033fd84baeb1e112e7e54`；下载的脱敏兼容性报告中
  sourceRevision 与该提交完全一致，checkoutState 为 clean。
- 产物版本 1.4.1 (141)，macOS 15.7.9 arm64；本次采样读取 253/490 个进程
  （原始覆盖率 51.63%），237 个明确权限拒绝，可读覆盖率为 100%。CPU 可用，
  GPU 不可用。可读覆盖率只解释刷新覆盖，不代表所有进程均可读或扩大动作权限。
- 托管 CI 未运行桌面原生测试；该部分由上述本机独立原生门禁验证。报告保留
  登录项注册、audit-token 信号验证未运行及系统权限未更改的限制。
- 后续仅记录此证据的文档提交不改变被验证代码，也不触发当前路径过滤的 CI。

## Deployment 1.4.2

- 源码 HEAD `4b1faee`；`Resources/Info.plist` 提升到 **1.4.2 (142)**。
- 部署前备份：
  - 1.4.1 bundle：`~/Library/Application Support/MemoryMonitor/backup-1.4.2-release/MemoryMonitor-1.4.1.app`
  - 历史/审计文件：同目录 `user-data/`，包含 `history.json`、`.clock`、`.journal`、`.lock`、`actions.jsonl` 及 clock/lock；备份时源数据尚无 v2 分段，仍按分段目录/ sidecar 形态保留恢复位置。
- 已部署到登录项注册路径：
  `~/Library/Application Support/MemoryMonitor/releases/1.3.1-final/MemoryMonitor.app`
- `codesign --verify --deep --strict` 通过；fixture 启动烟测成功；`open -Ra` 返回 0。
- `sfltool dumpbtm` 复核：登录项仍为 `enabled, allowed, notified`，URL 不变，Generation 13。
- 验证：全量 335 项中 334 通过；唯一失败为 `CleanupMotionTests` 的跨套件 AppKit 状态问题，四个原生套件隔离运行 7/7 通过；Release 严格并发构建通过。
- 真实用户历史尚未写入新 v2 格式；首次真实写入/修剪时才迁移。旧版本不能直接读取 v2 历史，回滚需同时恢复 `history.json`、`.segments` 和 sidecar。
- 未做 Developer ID/notarization、真实注销/登录验证；Smart Cleanup 仍保留 AppKit 正常退出语义。
