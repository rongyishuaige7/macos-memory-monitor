# v1.0.4 兼容性矩阵

> 2026-10-21 更新：`macos-14` runner 已按计划退役；当前 CI 使用
> `macos-15`，原生 GUI 测试在 CI 中显式跳过并在真实桌面运行。macOS 26
> 由本机验证。下列 v1.0.4 行保留为历史证据，不代表当前 CI 结果。

## 记录规则

每一行必须来自对应主机或虚拟机实际运行 `scripts/collect-compatibility-report.sh` 的结果。矩阵只摘录脱敏汇总，不保存原始进程列表、PID、路径、用户名、主机名或设备序列号。一次采样的覆盖率和耗时只能证明当时的运行状态，不能作为长期性能基准。

自动报告不会注册登录项、修改系统权限或发送进程信号。以下三项必须保持单独记录，未执行时不能由采样成功推断为通过：

- 登录项注册与系统批准流程；
- audit-token 绑定的信号发送；
- 系统权限变化前后的行为。

## 当前矩阵

| 日期 | 来源 | 产品 | 源码 | macOS | 架构 | 系统 | CPU | GPU | 进程采样 | 手工权限 / 登录项注册流程 / audit-token |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-29 | 本机桌面（v1.0.4c3b） | 1.0.3 (13) | `bb57ff6`, clean | 26.5.1 | arm64 | 部分可用且数据有效 | 可用 | 可用 | 424/671，63.19%，estimated 且可用 | 未执行 / 未执行（状态 `not_found`） / `passed`（专用子进程） |
| 2026-08-29 | 本机桌面（v1.0.4b 历史） | 1.0.3 (13) | `30571b8`, clean | 26.5.1 | arm64 | 部分可用且数据有效 | 可用 | 可用 | 406/636，63.84%，部分可用且数据有效 | 未执行 / 未执行 / 未执行 |
| 2026-08-29 | GitHub 托管 CI，[run 33254292547](https://github.com/rongyishuaige7/macos-memory-monitor/actions/runs/33254292547) | 1.0.3 (13) | `18e7e5f`, clean | 14.8.7 | arm64 | 部分可用且数据有效 | 可用 | 不可用 | 205/402，51.00%，部分可用且数据有效 | 未执行 / 未执行 / 未执行 |
| 2026-08-29 | GitHub 托管 CI，[run 33254292547](https://github.com/rongyishuaige7/macos-memory-monitor/actions/runs/33254292547) | 1.0.3 (13) | `18e7e5f`, clean | 15.7.7 | arm64 | 部分可用且数据有效 | 可用 | 不可用 | 261/490，53.27%，部分可用且数据有效 | 未执行 / 未执行 / 未执行 |

## 当前主机证据

- c3b 桌面报告 schema：`1`；源码 revision：`bb57ff6fa04af48d253751b56cde4f3e1d40d175`；工作区状态：`clean`；产品为 `1.0.3 (build 13)`，运行于 macOS `26.5.1` / `arm64`。
- 两份报告观测时间为 `2026-08-29T14:01:38Z`，进程覆盖率为 `424/671`（`0.6318926975`，约 `63.19%`）；247 个条目在扫描期间退出、身份变化或受系统权限限制。结果高于当前可用阈值，但不能视为完整枚举。
- 系统内存质量为 `estimated`，进程报告 `usable=true` 且 `samplingPerformed=true`；本轮 CPU 与 GPU 数据均有效（来自同一构建的发布验收采样）。
- 只读基线的 audit-token 为 `not_run`；显式 opt-in 报告为 `passed`，目标固定为 `dedicated_child`，信号固定为 `SIGKILL`，专用子进程已回收。
- 两份报告的登录项状态均为 `not_found`。`scripts/verify-desktop-integration.sh` 因该状态未能完成登录项验收而返回 `1`，但按设计保留 `0600` 报告；这不是隐藏失败。
- 本机未执行登录项注册/系统批准、重新登录自动启动或 TCC/隐私权限前后对照。打开 bundle 时还观察到 `LSMultipleInstancesProhibited=true` 将请求路由到已有实例，未创建第二个进程。
- c3b 报告文件位于 `/Users/rongyi/Applications/MemoryMonitor-c3b/desktop-baseline.json` 和 `/Users/rongyi/Applications/MemoryMonitor-c3b/desktop-audit.json`，只作为本机复核材料，不提交到仓库。

## 历史 v1.0.4b 本机证据

- 当时报告 schema 为 `1`；源码 revision：`30571b873659f287a2bc6694e9e704a92b2d7271`；工作区状态：`clean`。
- 完整采样总耗时约 `45.7 ms`，其中进程扫描约 `44.0 ms`；进程覆盖率为 `406/636`，230 个条目在扫描期间退出、身份变化或受系统权限限制。
- 系统内存使用率按可回收内存估算，CPU 与 GPU 数据有效；登录项注册、audit-token 信号和系统权限变化均未执行。

## macOS 14/15 CI 证据

- 成功 workflow 为 [Compatibility Matrix run 33254292547](https://github.com/rongyishuaige7/macos-memory-monitor/actions/runs/33254292547)，源码 revision 为 `18e7e5f6544e192628681a99d42f09dfc9101ee2`，两份报告均为 schema `1` 和 `clean` checkout。
- macOS 14.8.7 使用 Xcode 16.2 / Swift 6.0.3；228 项测试、Debug/Release 严格并发构建和 Release probe 通过。完整采样约 `23.3 ms`，进程扫描约 `23.0 ms`，覆盖 `205/402`。
- macOS 15.7.7 使用 Xcode 16.4 / Swift 6.1.2；228 项测试、Debug/Release 严格并发构建和 Release probe 通过。完整采样约 `26.9 ms`，进程扫描约 `26.6 ms`，覆盖 `261/490`。
- 两个 runner 的系统数据均为可用的估算值，CPU 数据可用；虚拟环境中的 IOAccelerator 未提供可读 GPU 利用率，因此 GPU 明确记录为 `unavailable`，不视为 GPU 实机验证通过。
- 两份 artifact 分别为 `compatibility-macos-14-arm64` 和 `compatibility-macos-15-arm64`，保留 14 天。复核的标量路径仅属于 schema 规定的产品、平台、采样质量、计数、耗时和限制项，不包含进程或设备身份。
- 矩阵首次运行实际发现并修复了旧工具链差异：runner Xcode 选择、Swift 6.0/6.1 的 Optional 穷尽匹配、actor 隔离闭包经文件锁传递，以及 Xcode 16.2 的同步闭包和 Darwin 导入标注。最终成功 run 覆盖全部修复。

## 复现方式

标准输出只包含 JSON；构建进度和采集提示写入标准错误：

```bash
./scripts/collect-compatibility-report.sh > /explicit/local/path/compatibility.json
```

脚本从 `Resources/Info.plist` 读取产品版本，并记录当前 Git revision。已跟踪文件有改动，或者 `Package.swift`、`Resources/`、`Sources/`、`scripts/` 下存在未跟踪构建输入时，报告会把 checkout 标记为 `modified`。

## 尚缺环境

- macOS 14/15 真实登录桌面：ServiceManagement 批准流程、真实 IOAccelerator、历史持久化和应用生命周期；当前 CI 只覆盖 14.8.7/15.7.7，不等于精确验证 macOS 14.0；
- 不同系统权限状态：进程覆盖率、登录项批准和系统设置恢复路径；
- audit-token 可用与不可用环境：只使用专用测试进程验证绑定信号，禁止对第三方进程执行；
- x86_64：当前发布脚本只生成 arm64 bundle，是否扩展架构支持必须先单独决策。

当前矩阵证明源码能在三个 arm64 macOS 主版本执行既定只读采样，其中 macOS 14/15 来自托管虚拟环境。它不宣称所有次版本、设备、权限状态或桌面集成均兼容。

## v1.0.4c 自动采集实现

- GitHub Actions 使用明确的 `macos-14` 和 `macos-15` arm64 标签，不使用会随时间迁移的 `macos-latest`；
- `scripts/verify-compatibility.sh` 要求显式报告路径和预期平台，运行测试、严格并发构建、Release probe 和结构化采集，并校验实际系统主版本、架构、系统可用性、进程扫描和三项限制；
- 工作流显式选择 macOS 14 的 Xcode 16.2 和 macOS 15 的 Xcode 16.4，避免 runner 默认工具链低于 SwiftPM 6.0 要求；
- 报告以短期 artifact 保存，只有 workflow 实际完成并复核 JSON 后，结果才会进入“当前矩阵”；
- runner 证据会明确标为“GitHub 托管 CI”，不用于判断真实桌面登录项、TCC 权限切换、GPU 可用性或 audit-token 发信号；
- `macos-14` runner 已进入弃用期并计划在 2026-11-02 退役；退役后的 macOS 14 回归必须转移到自托管或其他真实主机。
