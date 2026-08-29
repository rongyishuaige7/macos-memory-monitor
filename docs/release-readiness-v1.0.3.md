# v1.0.3 发布基线

## 范围

本批次把已经完成验收的 v1.0.3e 版本统一写入源码和默认构建入口：

- `Resources/Info.plist` 作为 App bundle 的默认版本来源；
- 构建脚本默认读取该版本，不再维护第二套硬编码版本号；
- README 顶部明确当前实现版本和签名状态；
- 保留 `APP_VERSION`、`BUILD_NUMBER` 环境变量覆盖能力，方便发布流水线生成候选版本。

## 非目标

- 不改变采样、历史、建议或进程操作行为；
- 不在本批次引入 Developer ID、notarization 或 App Sandbox；
- 不修改历史阶段的验收记录；
- 不触碰用户未跟踪的实验文件。

## 设计

`Info.plist` 保存默认的 `CFBundleShortVersionString` 和 `CFBundleVersion`。`scripts/build-app.sh` 在读取配置后通过现有的 `plutil` 提取这两个值；只有显式提供环境变量时才覆盖它们。这样本地构建、App bundle 元数据和文档可以围绕一个明确的默认版本收口。

## 风险

- 旧脚本调用者可能依赖 v1.0.1 默认值；因此保留环境变量覆盖，并在构建输出中打印最终版本；
- 版本统一不等于正式发布资格，当前仍使用 ad-hoc 签名；
- `plutil` 已是构建脚本的既有前置依赖，提取失败必须让脚本立即退出，不能静默生成无版本 bundle。

## 验收标准

- 不设置版本环境变量时，脚本使用 `Info.plist` 中的 `1.0.3 / 13`；
- 设置 `APP_VERSION` 和 `BUILD_NUMBER` 时，覆盖值只影响生成的 bundle，不回写源码 plist；
- 源码 plist 通过 `plutil -lint`；
- Swift 测试、Debug/Release 严格并发构建、Release probe 和 App bundle 签名检查继续通过；
- `git diff --check` 通过，用户实验文件保持未跟踪且未被修改。

## 分阶段交付

1. **v1.0.3 发布基线**：统一默认版本来源并完成本地构建验证。
2. **后续兼容性批次**：在不同 macOS 版本和权限状态下验证采样、登录项和 audit-token 行为。
3. **正式发布批次**：单独决定 Developer ID、notarization、安装升级和沙盒策略。
