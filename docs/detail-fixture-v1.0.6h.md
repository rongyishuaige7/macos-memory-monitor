# v1.0.6h：可信临时根与 fixture 启动边界

## 范围

本阶段收紧隔离 UI-check 的临时目录信任边界。v1.0.6g 允许把传入环境中的任意 `TMPDIR` 当作 storage root 的信任锚点；手工设置 `TMPDIR` 到项目或其他持久目录时，fixture 可能把合成数据写出预期范围。本阶段改为只信任系统 Darwin 用户临时根和规范化后的 `/tmp`，并让 Core、fixture writer 与启动器使用同一规则。

## 非目标

- 不改变正式启动的 Application Support 默认目录、采样器或历史/审计保留策略；
- 不把 `TMPDIR` 环境变量改写成持久化配置，也不承诺解决临时目录本身的 TOCTOU 竞态；
- 不改变启动器现有 `output/{storage,tmp,home}` 目录布局；
- 不在无头会话中伪造详情页 AX 结果，不向真实进程发送信号；
- 不修改用户已有的 `ScratchProbe.swift`、`ScratchProbe 2.swift` 或其他未跟踪文件。

## 架构

1. Core 通过 Darwin `confstr(_CS_DARWIN_USER_TEMP_DIR)` 获取与进程环境解耦的用户临时根，并与 canonical `/tmp` 组成固定信任根集合。`isolatedRootURL(environment:)` 忽略任意 `TMPDIR` 值，只接受信任根的严格后代和完整路径组件边界。
2. Core 保留一个仅供 `@testable` 回归测试使用的 trusted-root 注入入口，使路径规则可以在不修改全局环境的情况下覆盖项目路径、前缀相似路径、符号链接和 sibling 目录。
3. `memory-monitor-fixture` 复用 Core 的 isolated-root 解析，再执行现有的空目录、权限、符号链接和输出文件校验；fixture writer 不再独立信任 `ProcessInfo` 中的 `TMPDIR`。
4. `scripts/launch-ui-check.sh` 用 `getconf DARWIN_USER_TEMP_DIR` 和 `/tmp` 校验 `--output-dir`。这样 `storage` 与 `tmp` 作为 output 的 sibling 都能被 App 接受，而把 `TMPDIR` 指到项目或普通持久目录会在启动前失败。

## 风险

- `confstr` 返回值可能带尾部斜杠或超过固定缓冲区，解析失败时必须安全退回只包含 `/tmp` 的信任集合；
- `/tmp` 在 macOS 上可能解析为 `/private/tmp`，候选目录和信任根必须在同一 canonical 路径空间比较；
- 启动器的 output 根、storage sibling 和传给子进程的 isolated `TMPDIR` 不同层级，不能错误地只接受 `TMPDIR` 的子树；
- fixture writer、App 和 shell launcher 若规则漂移，会出现“写入成功但 App 回退生产模式”的混合状态；
- 纯值检查仍不能替代启动器对目录所有权、权限、空目录和并发替换的文件系统检查。

## 验收标准

- `/tmp` 和系统 Darwin 临时根下的 canonical 子目录均可接受；根本身、前缀相似目录、项目目录和任意非系统 `TMPDIR` 锚点均拒绝；
- dot segments、尾部斜杠、符号链接、NUL 和换行输入有确定结果，且比较遵循完整组件边界；
- fixture writer 与 launcher 在正常临时 output 根下成功，在不可信 TMPDIR/持久目录下 fail closed；
- App 的 paired fixture 配置矩阵、现有 Core/App 全量测试、严格 Debug/Release 构建和 `verify-release.sh` 保持通过；
- Core、fixture writer 和 launcher 的路径规则由同一契约文档记录，并分批提交、推送；
- 两个 `ScratchProbe` 文件及其他用户未跟踪文件保持原样。

## 分阶段交付

1. **设计契约**：记录固定系统临时根、sibling 布局和失败语义。
2. **Core 规则**：实现 confstr 根解析、测试注入入口和路径回归矩阵。
3. **端到端同步**：让 fixture writer 与 shell launcher 复用/对齐 Core 规则，验证正常和恶意环境。
4. **验证交付**：运行全量门禁，更新本文档；真实详情 AX 检查仍在稳定登录桌面会话中单独进行。

## 实施结果（2026-08-31）

本阶段的代码已经落地，三条入口共享固定的系统临时根和完整组件边界契约：Core
使用 `confstr(_CS_DARWIN_USER_TEMP_DIR)` 与 canonical `/tmp`，fixture writer
复用 Core 解析后再执行创建前后的文件系统检查，launcher 使用
`getconf DARWIN_USER_TEMP_DIR` 与相同的 `/tmp` 边界。调用方提供的 `TMPDIR`
不会再成为信任锚点；它只可作为构建/fixture 子进程的临时环境，并且 launcher
会把该环境收敛到已验证的系统根。Core 在值级解析时允许仍位于可信根内的
symlink ancestor；writer 和 launcher 在实际创建目录前额外拒绝普通 symlink，
只放行并复核 macOS `/tmp`、`/var` 系统别名。

具体实现包括：

- Core 增加测试注入的 trusted-root overload、完整组件边界比较、现存和悬空
  symlink 的 canonical 解析，以及 Darwin `/tmp`、`/var` 别名兼容；Core 对指向
  信任根外的目标拒绝，普通非系统 symlink 则由 fixture/launcher 的创建前检查
  拒绝。
- fixture writer 对输入执行首尾空白规范化、内部换行/NUL 拒绝、空目录和
  `0700/0600` 权限检查，并在 `mkdir` 后再次确认最终路径没有被替换。
- launcher 保留 lexical 与 canonical 两种路径表示，拒绝项目树、根目录、前缀
  碰撞、最终或祖先普通 symlink、悬空 symlink 前缀和并发替换；还显式预检
  `chmod` 等运行时依赖，避免在路径创建后才出现命令缺失。

## 验证证据

- `swift test --filter StoragePathTests`：10/10 通过。
- `swift test --filter MemoryMonitorUIFixtureTests`：7/7 通过。
- `swift test --parallel`：279/279 通过。
- `swift build --configuration debug -Xswiftc -strict-concurrency=complete` 和
  `swift build --configuration release -Xswiftc -strict-concurrency=complete`：通过。
- Release fixture writer 正常临时根生成 240 条 history、239 条 journal 增量和
  12 条 audit；项目目录、普通 symlink 祖先和非系统持久目录均 fail closed。
- `./scripts/verify-release.sh`：通过；本次 Release probe 为 `456/648`（部分可用），
  兼容性报告为 schema `1`、macOS `26.5.1`、arm64，App 版本 `1.0.3`、build `13`，
  bundle 的 `codesign --verify --deep --strict` 通过。
- launcher 在 `/tmp` 下、调用者 `TMPDIR` 指向项目且参数带首尾空白的空目录上完成了
  fixture、bundle、Launch Services 及环境继承检查；验证启动的专用 PID 已按精确
  可执行路径收尾，未向其他实例发送信号，也未执行 AX 点击。
- `zsh -n scripts/launch-ui-check.sh` 与 `git diff --check`：通过；本轮所有临时
  fixture、bundle 和专用进程均已清理，正式存储和未跟踪用户文件未触碰。

## 当前缺口与下一阶段

- 真实详情页的桌面 AX 验收（多成员、长审计文本、顶部/末端滚动和关闭入口）
  仍需在稳定登录桌面会话中只读完成；无头测试不宣称这部分通过。
- 路径检查仍明确不承诺消除文件系统 TOCTOU；launcher 和 writer 的创建前后复核
  只降低竞态窗口。跨 macOS 14/15 CI 尚未运行 Launch Services fixture。
- 下一阶段优先收集真实 fixture 详情页的 AX 证据，随后评估登录启动、Developer ID
  签名/notarization 与 App Sandbox 的发布策略；在此之前保持登录项和权限状态不变。
