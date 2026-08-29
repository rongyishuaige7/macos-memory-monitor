# v1.0.4c3 桌面集成验证

## 范围

在真实 macOS 登录桌面中，为以下三类行为建立可复核证据：

- 从实际 `MemoryMonitor.app` 读取 `SMAppService.mainApp` 登录项状态；
- 记录当前权限环境下的进程采样质量和覆盖率，并允许用户改变系统设置后再次采集对照；
- 只对验证工具自己创建的专用子进程执行 audit-token 绑定信号，确认生产强制结束路径能建立内核身份绑定。

本阶段只补充桌面集成验证入口和本机证据，不改变产品的登录项默认值、进程操作策略、权限要求或兼容性报告 schema。

## 非目标

- 不由脚本注册、注销或批准登录项；这些变化只能由用户在应用界面和系统设置中明确操作；
- 不自动授予、撤销或重置 TCC/完全磁盘访问权限，也不调用 `tccutil reset`；
- 不接受 PID、进程路径或信号值作为输入，不向现有进程、第三方进程或系统进程发送信号；
- 不自动注销、重启或终止当前桌面会话；
- 不把一台 macOS 26 主机的结果外推为 macOS 14/15 实机结论；
- 不把读取到登录项状态等同于已经验证登录后自动启动，后者必须经过真实会话重启或重新登录；
- 不在报告中保存 PID、进程名、路径、用户名、主机名、设备标识或系统设置内容。

## 架构

`memory-monitor-app` 增加一个严格匹配参数的桌面诊断入口。入口在构造 SwiftUI `App`、采样循环、历史存储和操作审计之前完成参数分流，避免一次性诊断意外启动常驻应用或写入产品数据。无诊断参数时继续进入现有 `MemoryMonitorApp`，行为不变；未知参数直接失败，不降级启动 GUI。

诊断入口输出 schema 版本固定的脱敏 JSON，包含产品版本、源码 revision/工作区状态、macOS 版本、进程架构、当前登录项状态、进程采样质量/计数/覆盖率、audit-token 检查结果和明确限制项。登录项状态只使用有限枚举；系统错误只转换为有限结果或经过长度和控制字符清理，不输出任意外部文本。

默认命令只读取当前状态。audit-token 检查需要同时满足固定命令参数和 `MEMORY_MONITOR_ALLOW_AUDIT_TOKEN_TEST=1`。检查器自行启动固定的短生命周期子进程，不提供目标参数；取得初始 `ProcessSnapshot` 后调用生产 `LiveProcessActionRuntime.sendForce`。该方法禁止无 token 降级，因此只有取得 audit token、完成最终身份复核并由 `proc_signal_with_audittoken` 成功发送 `SIGKILL` 时才能记录为通过。无论检查成功或失败，检查器都负责结束并回收自己创建的子进程。

`scripts/verify-desktop-integration.sh` 负责校验显式 `.app` 路径、bundle identifier、签名、架构和 JSON 结构。脚本要求显式报告输出路径，不安装应用、不改变登录项或权限；带 audit-token 参数时再次检查 opt-in 环境变量。报告只属于所传入的那个 bundle 和当时桌面会话。

## c3b 本机证据（2026-08-29）

本次使用同一份 arm64 构建和同一路径完成两次采集：`/Users/rongyi/Applications/MemoryMonitor-c3b/MemoryMonitor.app`。bundle 版本为 `1.0.3 (build 13)`，源码 revision 为 `bb57ff6fa04af48d253751b56cde4f3e1d40d175`，checkout 状态为 `clean`，运行环境为 macOS `26.5.1` / `arm64`。报告写入本机 `0600` 文件，未纳入仓库：

- 只读基线：`/Users/rongyi/Applications/MemoryMonitor-c3b/desktop-baseline.json`；schema `1`，观测时间 `2026-08-29T14:01:38Z`，进程采样 `424/671`（`0.6318926975`，约 `63.19%`），质量为 `estimated`，`usable=true`、`samplingPerformed=true`。扫描期间有 247 个条目退出、身份变化或受权限限制。
- 显式 audit-token 检查：`/Users/rongyi/Applications/MemoryMonitor-c3b/desktop-audit.json`；除上述采样结果外，`auditToken.result=passed`，目标固定为 `dedicated_child`，信号固定为 `SIGKILL`。专用 `/bin/sleep` 子进程已成功终止并回收。
- 两份报告的 `loginItem.state` 都是 `not_found`。因此验证脚本按设计返回非零并保留报告，不能把“读取到状态”解释为登录项注册或批准成功。
- 本次没有执行登录项注册/系统批准、关闭并重新登录后的自动启动验证，也没有改变 TCC/隐私权限或采集权限变化前后对照；对应限制项继续保留在报告和矩阵中。
- 尝试以 Finder/Launch Services 打开该 bundle 时，`LSMultipleInstancesProhibited=true` 使请求路由到已有的 `MemoryMonitor.app` 实例，未创建第二个进程。该行为记录为单实例配置的桌面观察，不作为登录后自动启动证据。

上述两份报告的只读字段和限制项均通过 `scripts/verify-desktop-integration.sh` 的结构校验；登录项未发现导致的退出码 `1` 是待人工步骤的明确信号，不是脚本成功状态被吞掉。

## 人工验证流程

1. 从当前源码构建并签名固定路径下的 `MemoryMonitor.app`，记录只读基线报告。
2. 以显式 opt-in 运行专用子进程检查，确认结果为 `passed`；失败时保留实际有限状态，不改用普通 `kill(2)` 冒充通过。
3. 启动同一路径的 App，在健康面板中由用户打开“登录时启动”，分别记录注册后、需要系统批准时和批准后的状态；随后由用户关闭开关并确认恢复为未注册。
4. 如需验证登录后自动启动，由用户自行重新登录，再确认同一 bundle 启动；工具不触发会话退出。
5. 先记录当前权限状态下的进程覆盖率。只有用户明确改变隐私设置并重新启动同一 bundle 后，才采集第二份报告并比较质量、计数和覆盖率；覆盖率变化本身不代表权限授予成功。
6. 只把实际执行且证据完整的步骤写入兼容性矩阵；未执行、需要批准或无法判断的步骤保持对应状态，不合并为“通过”。

## 风险

- `SMAppService.mainApp` 的结果依赖 bundle 路径、签名、当前登录会话和系统批准状态；从 SwiftPM 裸二进制运行不能替代 `.app` 验证。
- ad-hoc 重签名或移动 bundle 可能改变系统识别结果。一次状态序列必须固定同一路径和同一构建，报告需要记录源码 revision 与工作区状态。
- TCC 状态可能需要应用重启后才生效；前后报告必须记录独立时间，不能把缓存状态写成实时变化。
- audit-token 检查会对专用子进程发送 `SIGKILL`。双重 opt-in、固定子进程、不接受 PID 输入和 `defer` 清理缺一不可。
- 子进程可能在采样或发送前自行退出；这种竞态应报告为未通过或已退出，不自动重试到第三方目标。
- 直接执行 app bundle 内二进制的 stdout/stderr 与 Finder 启动不同；参数路由和 JSON 编码必须有单元测试，发布构建还需实际命令验证。
- 登录项注册和 TCC 前后状态需要人工操作，不能纳入无交互 CI，也不能因为自动门禁通过而标记完成。

## 验收标准

- 无参数启动保持现有菜单栏应用行为，诊断参数不会构造监视模型或写入历史/审计文件；
- 未知参数以非零状态退出，不会静默启动 GUI；
- 默认桌面报告不发送信号、不改变登录项、不打开系统设置，并把 audit-token 明确标记为未执行；
- audit-token 检查缺少参数或环境 opt-in 任一条件时拒绝运行；
- 检查器不接受 PID 输入，唯一目标由自身创建，并在所有退出路径回收；
- `passed` 只能来自生产 `sendForce` 的 `.sent`，因此不能由非绑定 `kill(2)` 降级产生；
- JSON 不包含专用子进程 PID、名称、路径或当前用户/主机身份，并通过结构和隐私测试；
- 验证脚本拒绝非绝对路径、错误 bundle identifier、非 arm64、无效签名、隐式输出路径和不符合 schema 的报告；
- 普通 `swift test` 不触发真实登录项、权限或进程信号；真实信号测试只在显式 opt-in 命令中执行；
- 本机窄测、全量测试、Debug/Release 严格并发构建、Release probe 和 App bundle 签名验收通过；
- 矩阵分别记录权限观察、登录项状态序列和 audit-token 结果，不用单一“通过”掩盖未执行步骤。

## 分阶段交付

1. **v1.0.4c3a（已完成）**：定义桌面证据、安全门和人工验证边界。
2. **v1.0.4c3b（已完成）**：实现脱敏桌面报告、严格参数路由、验证脚本和专用子进程 audit-token 检查，并采集本机只读基线及专用子进程证据。
3. **v1.0.4c3c（待人工）**：由用户完成登录项注册/批准、重新登录自动启动和 TCC 权限前后对照；工具只记录实际完成的步骤。
4. **后续发布阶段**：在 macOS 14/15 真实设备复用同一流程，再决定最低版本和权限声明。
