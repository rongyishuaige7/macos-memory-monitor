# v1.0.6d 详情布局边界与可访问性收敛

## 范围

本阶段继续收敛进程详情和工作组详情的自适应布局契约：

- 让横向/纵向布局的宽度判定与实际子视图放置使用同一精确边界，避免理论上的半像素溢出；
- 让关系行（父进程链）使用可测量的标签、名称和尾部值，而不是依赖固定标签宽度的独立 `ViewThatFits` 候选；
- 让指标数值在 Dynamic Type 下随系统文本样式增长，并保护极窄正文提案不产生不可访问的横向内容；
- 用纯值契约和 `NSHostingView` smoke fixture 锁定上述行为。

## 非目标

- 不改变采样、历史记录、工作组归因、进程操作权限或确认流程；
- 不调整详情 sheet 的最小/理想窗口尺寸、导航路由或信息架构；
- 不引入第三方布局、快照或 UI 测试依赖；
- 不向正式实例、c3c 实例或任何真实进程发送信号；
- 不修改用户已有的 `ScratchProbe.swift` 和 `ScratchProbe 2.swift`。

## 架构

`DetailLayoutPolicy` 继续是所有阈值的唯一来源。布局层只负责测量和放置：

1. `modeForRequiredWidth` 使用精确的 `available >= required` 判定；布局在放置时把计算出的子视图宽度和起点限制在 bounds 内。
2. 新的关系行测量布局读取每个子视图的 ideal size，按同一策略决定 inline 或 stacked；关系行的生产视图和契约测试都调用同一纯函数。
3. 指标 tile 的主要数值采用动态系统文本样式，保留有限的视觉上限；正文宽度解析对非正/非有限 viewport 做保守处理，并在极窄提案下优先纵向布局。
4. smoke fixture 继续使用固定字符串和 `NSHostingView`，覆盖默认字号、`accessibility3`、边界宽度和极窄宽度；不把单机 AX 树结果冒充为 CI 自动化证明。

## 风险

- SwiftUI `Layout` 的 ideal size 和 `ViewThatFits` 测量会随 macOS 字体和版本变化；契约测试只锁定决策，不锁定像素；
- 去掉容差可能让刚好不足一个小数点单位的窗口更早切换为 stacked，详情高度会增加但信息可读性更高；
- 关系行从固定标签宽度改为测量宽度后，中文标签和大字号下的换行点会变化；
- Dynamic Type 的系统文本样式可能改变指标网格行高，必须确认滚动容器仍能到达底部；
- 极窄 viewport 仍可能由宿主窗口或系统滚动条产生额外裁剪，生产 sheet 的最小宽度只提供当前平台的保护。

## 验收标准

- `modeForRequiredWidth` 在 `required - 0.01`、`required` 和 `required + 0.01` 上给出可解释且无溢出的结果；
- 关系行契约覆盖短标签、长标签、长名称、长尾部值和 `NaN`/无限提案，生产布局不再保留固定 `52pt` 标签依赖；
- 指标 tile 在 `.accessibility3` 下测量高度有限且大于默认字号，数值不使用固定字号压缩到不可读大小；
- 极窄 fixture 的测量宽度和放置范围不超过其 bounds，详情内容仍有正高度；
- `swift test --package-path . --parallel`、严格并发 Debug/Release 构建和 `./scripts/verify-release.sh` 通过；
- 每个实现/文档切片单独提交并推送到 `origin/main`，两个 `ScratchProbe` 文件始终未跟踪。

## 分阶段交付

1. **边界契约**：去除半像素容差、增加放置范围和极窄宽度测试。
2. **关系行统一测量**：抽取专用 Layout，接入父进程行并补充 smoke 覆盖。
3. **Dynamic Type 与指标可读性**：改用动态文本样式，验证大字号和滚动高度。
4. **验证交付**：运行全量门禁，更新本记录，分批提交并推送。
