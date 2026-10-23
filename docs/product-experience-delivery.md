# 产品体验 U1–U8 候选交付记录

日期：2026-10-23  
实现源码：`c687ded`（当前复审修复源码）
产品版本：1.4.2 (142)，**未 bump、未部署**

## 交付范围

| 阶段 | 实现提交 | 主要交付 |
| --- | --- | --- |
| U1 | `659cdef` | 统一状态/禁用原因、健康项直达、只读本地数据检查、脱敏摘要 |
| U2 | `926ab20` | 概览/菜单压力结论、依据、主行动和有效时间统一 |
| U3 | `aab8a4b` | 检查→冻结预览→确认→原安全链路；30 秒有效、最多 8 个、不补位 |
| U4 | `c78bf61` | 独立已授权名单、未运行单项撤销、身份变化提示、显示元数据 |
| U5 | `cfe9562` | 原始峰值/取点、压缩/交换增量、工作组质量、覆盖与断档 |
| U6 | `edf17d4` | 会话搜索/排序/展开/历史范围、跟随系统、快捷键、高级工具入口 |
| U7 | `b7d15b7` | 可见面需求合并、系统/进程间隔分层、生命周期注销 |
| U8 | `9672820` | UI 检查 fixture 兼容维护锁；最终组合验收与交付记录 |

## 验证证据

| 项目 | 结果 |
| --- | --- |
| 完整 `verify-release.sh` | `/private/tmp/mm-ux-u8-gate-c687ded`，`status=failed`；`DesktopMotionTests` inactive 会话失败 |
| 非原生 artifact gate | `/private/tmp/mm-ux-u8-gate-c687ded-noskip`，`status=passed`，`native_tests=skipped`（不冒充完整原生通过） |
| 源码/构建 | source `c687ded`，checkout clean，build inputs digest `29882a10512df8b260d8cb1f3256841ae1ad06a67321ebaa3eb3174933e65f3a` |
| 非 GUI | 422 项通过；`non_gui_test_scope` 通过 |
| 原生 | 4 套隔离测试 7/7 通过（CleanupMotion 2、DesktopMotion 1、DesktopWindow 3、SmartCleanupNative 1） |
| 产物 | 签名、BuildProvenance、probe、兼容性报告、桌面报告、输入稳定性均通过 |
| CI | [run 39955036496](https://github.com/rongyishuaige7/macos-memory-monitor/actions/runs/39955036496)，macOS 15 arm64 成功 |
| UI fixture | `/private/tmp/mm-ux-ui-check-c687ded`，Launch Services 启动、240 历史/239 journal/12 审计；本次 PID 已停止 |
| 性能 | U7 连续性能对照**未执行**，见 [product-experience-performance-u7.md](product-experience-performance-u7.md) |

## A01–A18 覆盖

- A01/A02：U1 状态投影、typed recovery error、健康路由、动作禁用原因测试。
- A03：U2 概览/菜单共享决策、正常/压力/不可用和有效时间测试。
- A04–A08：U3 冻结预览、最多 8 个、不补位、30 秒失效、完整/不完整检查；
  U4 完整授权身份、未运行撤销、身份变化；既有 SmartCleanup/ProcessAction
  安全回归继续通过。
- A09：U4 旧偏好兼容、显示元数据、单项撤销和身份不继承测试。
- A10/A11：U5 原始峰值、120 秒增量边界、工作组完整/部分/未知/估算、覆盖
  与断档测试。
- A12/A13：U1 只读检查前后文件/hash/权限/mtime 不变、未完成恢复标记可见；
  摘要白名单、0600、拒绝覆盖测试。
- A14：生产 fixture 执行总闸保持关闭；UI fixture 只启动隔离实例。
- A15/A16：U6 会话上下文、搜索命中成员、稳定排序、滚动锚点、跟随系统、
  快捷键和高级工具入口；原生 DesktopWindow/SmartCleanup 套件通过。
- A17：U7 需求合并/压力合并/稀疏页面/多消费者生命周期测试；性能对照待补。
- A18：上述完整门禁、CI、来源和输入稳定性证据。

## 复审修复

- P1 预览过期：确认按钮重新读取当前单调时间；`SmartCleanupController.start(preview:)`
  再校验 preview ID、有效期和选中集合，过期预览不会发出退出请求。
- P2 历史归因：工作组归因时间与记录时间偏差超过 300 秒（含未来）标为
  `.unknown`，不再显示 `.complete`。
- P2 采样唤醒：可见需求集合变化即递增 revision 并唤醒等待；页面切换不会
  继续沿用旧 20 秒等待。
- P2 可见性恢复：隐藏只注销可见需求，保留实际页面；恢复时重新注册原页面，
  不再固定回 `.overview`。
- P2 U6 列表稳定：已有组顺序在读数刷新时保持，新组追加；保存组滚动锚点，
  切页/返回恢复；提供“固定排序”开关。

## 桌面走查

已用 `launch-ui-check.sh` 启动隔离 fixture，确认构建来源、签名、最小环境、
历史/审计计数和 Launch Services 启动路径；未对真实用户数据执行操作。
**未完成**方案要求的完整人工桌面矩阵（默认/最小窗口、深浅/跟随系统、长文本、
键盘、提高对比度、减少透明度、减少动态效果及五条产品任务走查）。因此本记录
不把自动化通过等同于真人可用性验收。

## 限制与未完成

- U7 连续性能对照未执行，不能声称 CPU/RSS/扫描次数下降百分比。
- 完整人工桌面矩阵和产品任务走查未执行。
- macOS 14 真机/runner、Developer ID、公证、真实登录/注销、登录项路径迁移
  仍按 S7 记录保留，不能由 macOS 15 结果外推。
- 未 bump 版本、未部署；已安装 1.4.2 bundle 和真实用户数据未修改。
- U3/U4 的 UI fixture 已覆盖渲染和状态投影，但未开放生产 fixture 的真实退出
  能力，符合安全边界。

## 结论

U1–U8 的代码和自动化候选交付已完成，非原生 artifact 门禁与 CI 全绿；完整原生门禁仍受 inactive 会话偶发失败。该候选仍缺 U7
连续性能对照、完整人工桌面走查和外部发布条件，不能标记为已正式发布。
