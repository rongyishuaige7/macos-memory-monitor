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
