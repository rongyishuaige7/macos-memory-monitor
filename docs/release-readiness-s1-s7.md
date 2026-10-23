# S1–S7 组合验收与发布记录

日期：2026-10-23  
源码 HEAD：`fcf2d91`  
产品版本：1.4.2 (142)，**未 bump、未部署**

## 结论

S1–S7 的代码、数据恢复工具、审计/扫描边界和组合证据已完成。当前源码可作为
1.5.0 的候选基础，但**还不是可直接部署的发布产物**：

- 当前 GUI 会话下完整原生门禁未全绿：`DesktopMotionTests` 无法激活测试窗口，
  其余 6 个原生用例通过。
- 非 GUI 门禁、构建、签名校验、probe、桌面报告和数据升级/回滚演练通过。
- Developer ID、公证、真实登录/注销、macOS 14 真机回归仍未执行。

## 证据

| 证据 | 路径/结果 |
| --- | --- |
| 完整门禁（当前 HEAD） | `/private/tmp/mm-s7-gate-full`，`status=failed`，失败步骤 `native_tests` |
| 完整门禁中的非 GUI 范围 | 383 项通过；`non_gui_test_scope` 通过 |
| 原生隔离套件 | `CleanupMotionTests` 2、`DesktopWindowTests` 3、`SmartCleanupNativeTests` 1 通过；`DesktopMotionTests` 1 失败（inactive） |
| 原生日志 | `/private/tmp/mm-s7-gate-full/native-tests`、`/private/tmp/mm-s7-native-extra` |
| 非原生完整 release gate | `/private/tmp/mm-s7-gate-skip`，`status=passed`，`native_tests=skipped`（显式记录） |
| 门禁摘要 | source `fcf2d91`，checkout clean，verification digest before==after |
| CI | [run 39911542300](https://github.com/rongyishuaige7/macos-memory-monitor/actions/runs/39911542300)，macOS 15 arm64 成功 |
| 数据升级/回滚 | v2 fixture → backup → 恢复 v1 backup → 恢复 v2 backup，最终 `healthy/segmentedV2`，无 v1/v2 混合 |

### 升级/回滚演练细节

1. `memory-monitor-fixture` 在空临时根生成 v2 数据：240 条历史、239 条 journal、
   12 条审计、1 个分段。
2. `memory-monitor-storage backup` 生成 v2 备份，`restorable=true`，
   `historyStatus=healthy`。
3. 在同一临时根恢复 v1 备份，`inspect` 得到 `legacy/legacyV1`，segments 为 0。
4. 再恢复 v2 备份，`inspect` 得到 `healthy/segmentedV2`，segments 为 1。
5. 全程未对真实数据执行 restore。

## 支持矩阵

| 维度 | 状态 | 说明 |
| --- | --- | --- |
| macOS 15 arm64 | 已验证 | CI 兼容矩阵成功；本地非 GUI 383 项通过 |
| macOS 14 arm64 | 最低版本，未验证 | 当前无可用 runner/真机；不能宣称当期回归通过 |
| Intel Mac | 未支持/未验证 | 构建目标为 arm64 |
| 本地 ad-hoc/Apple Development 签名 | 已验证 | `build-app.sh` + `validate_app` 通过 |
| Developer ID / 公证 | 未执行 | 外部签名资质和公证流程未提供 |
| 登录项路径 | 延后 | 仍指向 `releases/1.3.1-final/MemoryMonitor.app`；迁移需单独批准 |
| 真实登录/注销启动 | 未执行 | 需要人工桌面会话，自动查询不能替代 |
| history v1/v2 | 已验证 | 读取、检查、备份、恢复和整体替换均有测试 |
| 审计中断/队列 | 已验证 | 未确认状态、队列上限、原 event ID 重试、裁剪不完整标记 |
| 清理扫描预算 | 单元/设计验证 | 1.5 秒预算、单 worker、generation、取消；未做 10 分钟性能基线 |
| 完整 GUI/原生门禁 | 部分通过 | 6/7 原生用例通过；`DesktopMotionTests` 受 inactive 会话阻塞 |

## 未完成与停止条件

- 在可激活窗口的真实桌面会话重跑 `DesktopMotionTests`，并让完整
  `verify-release.sh` 生成全绿证据；当前失败证据必须保留，不能改成 skipped
  后宣称完整通过。
- 在 macOS 14 真机/runner 补兼容矩阵；不要把 macOS 15 结果外推到 14。
- 由具备 Developer ID/公证资质的发布者完成签名、公证和安装验证。
- 真实登录/注销、登录项路径迁移需要单独人工窗口和用户批准。
- 本记录不修改版本号；1.5.0 bump 与部署应在上述条件满足后单独决定。

## 复现命令

```bash
# 完整门禁（当前会话预期在 DesktopMotionTests 失败）
SWIFT_BUILD_FLAGS=--disable-sandbox \
SWIFT_TEST_FLAGS=--disable-sandbox \
./scripts/verify-release.sh /private/tmp/mm-s7-gate-full

# 非原生完整门禁（原生显式 skipped）
SWIFT_BUILD_FLAGS=--disable-sandbox \
SWIFT_TEST_FLAGS=--disable-sandbox \
VERIFY_RELEASE_SKIP_NATIVE_TESTS=1 \
./scripts/verify-release.sh /private/tmp/mm-s7-gate-skip

# 数据演练
memory-monitor-fixture --storage-root /private/tmp/mm-s7-fixture-root
memory-monitor-storage backup --root /private/tmp/mm-s7-fixture-root \
  --output /private/tmp/mm-s7-v2-backup
memory-monitor-storage restore --backup /private/tmp/mm-review6-backup \
  --root /private/tmp/mm-s7-rollback-root
memory-monitor-storage restore --backup /private/tmp/mm-s7-v2-backup \
  --root /private/tmp/mm-s7-rollback-root
```
