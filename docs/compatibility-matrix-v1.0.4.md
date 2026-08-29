# v1.0.4 兼容性矩阵

## 记录规则

每一行必须来自对应主机或虚拟机实际运行 `scripts/collect-compatibility-report.sh` 的结果。矩阵只摘录脱敏汇总，不保存原始进程列表、PID、路径、用户名、主机名或设备序列号。一次采样的覆盖率和耗时只能证明当时的运行状态，不能作为长期性能基准。

自动报告不会注册登录项、修改系统权限或发送进程信号。以下三项必须保持单独记录，未执行时不能由采样成功推断为通过：

- 登录项注册与系统批准流程；
- audit-token 绑定的信号发送；
- 系统权限变化前后的行为。

## 当前矩阵

| 日期 | 产品 | 源码 | macOS | 架构 | 系统 | CPU | GPU | 进程采样 | 手工权限/登录项/audit-token |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-29 | 1.0.3 (13) | `30571b8`, clean | 26.5.1 | arm64 | 部分可用且数据有效 | 可用 | 可用 | 406/636，63.84%，部分可用且数据有效 | 未执行 / 未执行 / 未执行 |

## 当前主机证据

- 报告 schema：`1`；源码 revision：`30571b873659f287a2bc6694e9e704a92b2d7271`；工作区状态：`clean`。
- 完整采样总耗时约 `45.7 ms`，其中进程扫描约 `44.0 ms`。
- 系统内存使用率按可回收内存估算，因此质量为 `estimated`，结构化数据有效。
- CPU 与 GPU 本轮均返回有效值。
- 进程覆盖率为 `406/636`；230 个条目在扫描期间退出、身份变化或受系统权限限制。覆盖率高于当前可用阈值，但不能视为完整枚举。
- 报告限制项为 `login_item_registration_not_run`、`audit_token_signal_not_run` 和 `system_permissions_not_changed`。

## 复现方式

标准输出只包含 JSON；构建进度和采集提示写入标准错误：

```bash
./scripts/collect-compatibility-report.sh > /explicit/local/path/compatibility.json
```

脚本从 `Resources/Info.plist` 读取产品版本，并记录当前 Git revision。已跟踪文件有改动，或者 `Package.swift`、`Resources/`、`Sources/`、`scripts/` 下存在未跟踪构建输入时，报告会把 checkout 标记为 `modified`。

## 尚缺环境

- macOS 14.x arm64：最低支持版本和 ServiceManagement 行为；
- macOS 15.x arm64：采样、IOAccelerator 和历史持久化回归；
- 不同系统权限状态：进程覆盖率、登录项批准和系统设置恢复路径；
- audit-token 可用与不可用环境：只使用专用测试进程验证绑定信号，禁止对第三方进程执行；
- x86_64：当前发布脚本只生成 arm64 bundle，是否扩展架构支持必须先单独决策。

在这些环境产生真实报告之前，矩阵只包含当前一行，不宣称完整跨版本兼容。

## v1.0.4c 自动采集计划

- GitHub Actions 使用明确的 `macos-14` 和 `macos-15` arm64 标签，不使用会随时间迁移的 `macos-latest`；
- 每个环境运行测试、严格并发构建、Release probe 和 `scripts/collect-compatibility-report.sh`，并校验报告中的实际系统主版本和架构；
- 报告以短期 artifact 保存，只有 workflow 实际完成并复核 JSON 后，才把结果追加到“当前矩阵”；
- runner 证据会明确标为“GitHub 托管 CI”，不用于判断真实桌面登录项、TCC 权限切换、GPU 可用性或 audit-token 发信号；
- `macos-14` runner 已进入弃用期并计划在 2026-11-02 退役；退役后的 macOS 14 回归必须转移到自托管或其他真实主机。
