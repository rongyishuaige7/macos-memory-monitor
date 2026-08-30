# v1.0.6c 详情布局回归矩阵

## 目标

v1.0.6b 已完成详情窗口的自适应实现和一次独立 bundle 实机检查。本批次把“看起来正常”收敛为可重复的回归契约：锁定窗口内实际内容宽度、字号放大后的回退边界，以及长值和底部内容仍可达的条件。

## 范围

- 把详情滚动容器的 viewport 到正文宽度换算提取为可测试规则；
- 补齐信息行、关系行、操作组和指标网格的精确边界测试，包括 `0.5pt` 容差、非有限值和自定义参数；
- 让操作组的“最小按钮宽度 + 实际标签宽度”规则由生产布局和测试共同使用，避免策略测试与真实布局分叉；
- 增加固定输入的 Dynamic Type 回归矩阵，验证字号放大时会切换到可读的纵向布局，而不是依赖单行压缩；
- 在独立 `NSHostingView` fixture 中检查长值、三按钮状态、窄宽度和指标列数的尺寸/高度契约；
- 把上一批独立 UI-check 的真实详情页面 AX 结果作为人工基线，并明确区分自动化 smoke 的覆盖边界。

## 非目标

- 不改变详情窗口的业务数据、采样频率、进程操作权限或确认流程；
- 不为测试向真实用户进程发送信号，不启动或终止正式/c3c 实例；
- 不引入 XCUITest、ViewInspector 或第三方快照依赖；
- 不把某一台 macOS 的字体像素尺寸外推为所有系统版本的视觉保证；
- 不调整详情窗口当前的最小/理想尺寸或整体视觉主题。

## 方案

### 纯值契约

`DetailLayoutPolicy` 继续作为唯一阈值来源，并新增正文宽度和操作按钮实际需求宽度的纯函数。测试覆盖：

- 进程正文 `500pt` 窗口减去 `40pt` 内边距后的 `460pt` 内容宽度；
- 工作组正文 `540pt` 窗口减去 `40pt` 内边距后的 `500pt` 内容宽度；
- 指标网格从一列到两列的 `370pt` 临界值；
- 信息/关系/操作布局在 `required - 0.51`、`required - 0.49` 和 `required` 的切换；
- `NaN`、正/负无穷、负间距、零按钮和异常最大列数的保守回退；
- 通过字号缩放后的模拟理想宽度，确认长标签会触发纵向排列。

指标列数计算还会在转换为 `Int` 前处理非有限参数和极大有限比值，避免异常输入触发运行时转换 trap；正常详情窗口的列数上限仍为两列。

### macOS smoke fixture

使用确定性的长字符串、固定时间和三个模拟按钮构造 `NSHostingView`。当前自动化测试只断言：

- 固定宽度下内容宽度保持在提案宽度内，测量高度为有限正数；
- `accessibility3` 大字号下长值 fixture 高度增加，说明布局没有继续压缩为不可读的单行；
- 三按钮 fixture 在窄宽度下高度增加，保留纵向 fallback 的空间；
- 指标 fixture 从两列降为一列时，每个 tile 仍有正行高。

这些 fixture 不直接创建真实 sheet，也不遍历 `AXUIElement` 树。上一批 v1.0.6b 的独立 UI-check 已记录真实进程/工作组详情的 AX 标签、滚动末端和关闭入口；本批不把那部分手工证据冒充为自动化断言。系统字体和 AX frame 可能随 macOS 版本变化，因此不保存或比较像素快照。

## 风险

- `NSHostingView` 需要真实 AppKit 主线程和登录桌面，不能在无窗口的 CI 环境中作为唯一门禁；纯值契约必须独立足够完整；
- `ViewThatFits` 的选择受系统字体和 Dynamic Type 影响，fixture 只验证信息可达和布局不塌陷；
- 关系行的 `relationRowMode` 是阈值契约，实际生产视图仍由 `ViewThatFits` 测量候选分支；两者未来若调整间距或尾部字段，需要同步复核；
- smoke fixture 不直接证明真实详情 sheet 的 AX 树、滚动末端或每个 `ViewThatFits` 分支，必须继续参考独立 UI-check 记录；
- `modeForRequiredWidth` 保留 `0.5pt` 取整容差，操作组在理论边界可能比 bounds 多出不足 `0.5pt`；
- 极窄提案低于正文最小宽度时仍可能产生理论横向溢出，生产 sheet 当前最小宽度保证不会进入该区间；
- 三按钮 fixture 不执行任何动作，不能替代真实信号发送后的状态机测试。

## 验收标准

- 新增回归测试覆盖上述边界，且与现有全量测试一起通过；
- `swift test --package-path . --parallel`、严格并发 Debug/Release 构建和 `scripts/verify-release.sh` 通过；
- `NSHostingView` fixture 在 `460pt`、`369pt` 和 `300pt` 内容宽度下完成默认字号与 `accessibility3` 检查；真实 `500x622pt`/`540x662pt` sheet 的 AX 结果沿用 v1.0.6b 独立 UI-check 记录；
- 远端 `origin/main` 保持线性提交，每个可独立回滚的实现/文档切片分别提交并推送；
- 两个用户原有 `ScratchProbe` 文件不进入提交。

## 分阶段交付

1. **回归契约（本批次）**：抽取纯值规则并补齐边界测试。
2. **Fixture smoke**：用确定性内容验证大字号、长值和窄布局的尺寸稳定性。
3. **验证交付**：运行全量门禁，更新本记录并分批提交推送。

## 实施结果

- `AdaptiveDetailScrollView` 的正文宽度和水平内边距由同一组策略常量计算，避免 viewport、最小内容宽度和 padding 在不同实现处漂移；
- 操作组按按钮实际 ideal width 计算需求宽度，测试与生产布局共用同一纯函数；
- 指标网格在 `+infinity` 测量提案时使用可落地的 intrinsic 宽度，在异常参数和极大有限宽度下先做保守回退，避免 `Double` 到 `Int` 的崩溃；
- 新增 5 个纯值契约测试和 3 个 AppKit smoke 测试；没有改变详情数据、进程操作或确认流程。

## 最终验证记录（2026-08-30）

- `git diff --check`：通过。
- `swift test --package-path .`：`249/249` 通过；新增契约 `5/5`、smoke `3/3`。
- `swift test --package-path . --parallel`：退出码 `0`；并行发现并运行同一组测试。
- `swift build --package-path . --configuration debug -Xswiftc -strict-concurrency=complete`：通过。
- `swift build --package-path . --configuration release -Xswiftc -strict-concurrency=complete`：通过。
- `./scripts/verify-release.sh`：通过；包含 Release probe、结构化兼容性报告、默认 arm64 App bundle 构建和 `codesign --verify --deep --strict`。本次报告为 macOS `26.5.1`、arm64，probe 读取 `379/597`（部分可用）。
- 独立 `NSHostingView` fixture：`460pt` 默认字号、`300pt`/`accessibility3` 长值和三按钮窄宽度、`460pt`/`369pt` 指标网格均通过；未启动或操作正式实例、c3c 实例及其 evidence 目录。
- 真实详情 sheet 的 AX/滚动末端人工证据沿用 [`detail-layout-v1.0.6b.md`](detail-layout-v1.0.6b.md) 中的独立 UI-check 记录，本批没有新增 AX 声明。

## 提交记录

- 源码与测试批次：`e48a716`，已推送至 `origin/main`。
- 文档批次：待本记录提交后单独推送；两个 `ScratchProbe` 文件保持未跟踪，不纳入任何提交。
