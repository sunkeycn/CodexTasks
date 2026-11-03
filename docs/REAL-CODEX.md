# 本机 Codex 任务关联与调试

2026-11-02：默认启动真实数据模式；`--demo` 保留模拟验收模式。CI/CD 仍为模拟，不触发真实部署。

## 使用流程

1. 在底部输入任务，例如“创建卡包”，回车保存，得到 `T#01`。创建时自动复制 `关联Codex Task【T#01】`。
2. 自己在 Codex 中编写提示词，把关联指令放在最后的独立一行并发送。
3. Codex Tasks 运行时监听本机 Codex 索引/日志变化后增量读取，300 ms 合并事件、60 秒低频兜底，关联后显示会话名称、工作目录和真实执行状态。也可在任务详情选择“手动关联现有会话”。
4. 会话工作目录自动成为项目目录；后续 `turn_context.cwd` 或 `exec_command.workdir` 新增的目录也会加入任务。Git 子目录归一化到仓库根目录，worktree 以本地 common git directory 合并仓库身份。
5. 项目列表显示去重后的关联任务总数和进行中数量。手动点击加号选择项目目录后，后续会话按相同目录复用项目。

任务名右侧「提示词」标签可重复复制；任务名下方的 `| 会话名称` 可以点击跳转。直接读取本地索引负责后续同步，设置中无需配置关联协议提示词。旧 `关联任务【T#01】` 继续兼容。

任务与会话严格一对一；重复同步幂等，冲突会提示且不会换绑。历史项目、分支和执行记录保留。任务是否完成由人工勾选，Codex 完成一轮不会自动完成任务。旧 `T-1` 编号仍可解析，统一显示 `T#01`。

这里设置的是**工作台里的项目工作目录**，不修改 Codex 的全局项目配置，也不移动正在运行的 Codex 会话。

## 真实数据与边界

- 只读 `~/.codex/state_*.sqlite` 和其索引指向的 `sessions/`、`archived_sessions/` 日志。不读取认证配置，不直接写 Codex 数据。未关联任务的「发送至Codex」使用本机 `codex exec --json --sandbox workspace-write --skip-git-repo-check --cd <当前工作区> -` 直接执行；完整 Prompt 通过 stdin 传入，固定首行为 `关联Codex Task【T#NN】`，第二行起为用户正文，正文为空时使用任务标题。CLI 沿用本机模型、认证与规则配置，本次运行限定工作区写入权限，不绕过沙盒或审批检查。收到 `thread.started` 后通过工作台服务立即关联会话，再用 `codex://threads/<id>` 打开。
- 只接入当前选中工作区绑定目录内的会话和目录；符号链接、Git 目录指向当前范围外时拒绝读取 Git。没有跨工作区源码扫描。首次预置 sunkey 和 ShopLnkit；可在左侧切换，应用设置中手动维护目录。
- 只对已经关联任务的目录执行只读 Git 元数据命令。记录当前分支、HEAD；无 Git 的目录仍可关联项目，并显示“未检测到 Git 分支”。不自动切换分支。
- 自动指令只认用户消息的独立行，忽略助手输出、工具输出和 Markdown fenced code；历史指令早于任务创建时间时不绑定。
- 项目发现依据结构化 cwd/workdir。只在自然语言里提到某项目，或者把目录藏在 shell `cd` 字符串里，目前不会推断关联。
- 用户在工作台填写的 Prompt 正文保存在任务 notes 中；不额外复制 Codex 会话中的提示词、代码或命令输出。发送回执仅存任务 ID、会话 ID、组件 PID、状态、时间和失败摘要。

这是针对本机存储格式的适配器，并非稳定公开 API。已用本机日志确认 `task_started`、`task_complete`、`turn_aborted`。当前可靠显示运行中、完成、中断；日志超过 3 分钟没有更新或源不可用则显示“同步未知”，不能据此判定失败。等待审批、等待输入与执行失败尚无完整可靠事件映射，不能当作已接通。工作台退出后停止同步；隐藏窗口仍保持事件监听和低频兜底，重新打开会补读日志。大日志优先读取尾部最多 2 MiB 的完整新事件，及时发布关联、标题与执行状态；旧历史按每次总计 2 MiB 分段补齐，未追平的旧历史不发布中间执行状态。补读期间仅在存在未读历史时继续调度。Git 检查使用独立队列：新目录立即刷新，已有目录在收到同步事件时最多每 15 秒刷新一次，较慢的 Git 不阻塞会话状态。

## 数据目录

默认真实数据目录：`~/Library/Application Support/FloatingWorkbench/Live/`。原 sunkey 数据库继续使用 `workbench.sqlite`；工作区配置和上次选择保存在 `workspaces.json`，其它工作区数据库保存在 `workspaces/<UUID>/workbench.sqlite`。任务号在各工作区独立分配，由会话 cwd 范围隔离识别。

旧模拟数据库 `~/Library/Application Support/FloatingWorkbench/workbench.sqlite` 保留，不迁移、不重编号。可用 `--data-directory PATH` 显式选择其他数据库。首次真实启动没有演示任务。

## 调试

```sh
./scripts/build-app.sh
./scripts/run.sh
swift run WorkbenchCLI sessions
swift run WorkbenchCLI create '创建卡包'
swift run WorkbenchCLI attach 'T#01' <session-id>
swift run WorkbenchCLI sync
swift run WorkbenchCLI status
```

CLI 与应用共用服务与事务；`sessions` 输出范围内会话元数据，`status` 输出当前工作区快照。所有命令使用应用上次选中的工作区及其目录范围。调试隔离数据：在命令前加 `--data-directory work/my-debug`，如 `swift run WorkbenchCLI --data-directory work/my-debug create '测试任务'`。

`sync` 是单次读取；长历史优先显示尾部状态，完整历史由应用持续补齐。任务详情提供“立即同步”、最近同步时间、同步错误提示。Prompt 替代原“说明”；不再展示完成标准和 Codex 执行明细，历史数据继续兼容。应用保存真实姓名/任务说明，分享调试快照前按需要去除私人内容。

## 验证

- `./scripts/test.sh`：核心、绑定冲突、真实格式增量读取、片段日志、目录边界、手动项目去重、动态追加项目、Git 分支更新与源丢失恢复。
- `./scripts/test-window.sh`：隔离数据中的原生窗口及视图模型验收。
- `outputs/真实会话验收.json`：使用本任务真实 Codex 会话在隔离数据库中的绑定与状态检查结果。

可选生命周期 Hooks 状态上报、配置与验证边界见 `docs/CODEX-HOOKS.md`。

## 固定首行与直接执行（1.3.4）

Prompt 编辑区的关联首行为只读文本，不能通过正文编辑器改写；可编辑区域只绑定 notes。保存与还原仅处理正文，关联行在组装发送内容时统一添加。旧 notes 首尾已经含有本任务关联行时，编辑和发送时自动去重，不删除正文中的其它任务编号。发送期间按钮禁用，已关联任务显示「打开Codex」。

`Contents/Helpers/CodexTaskRunner` 是独立的原生进程，消费 CLI JSONL，不保留工具输出。关闭、隐藏或重新打包工作台不会关闭它的输入输出流。小型回执写入当前数据库同级的 `codex-dispatch/`；工作台重启时恢复监听未结束的发送。退出码或执行失败会显示错误；意外失联标记为结果未确认，禁止自动重发。执行结束仍不改变人工勾选的完成状态。

开发验收通过模拟 CLI 验证完整输入、参数、会话绑定、较大输出与失败情况；没有将用户给出的卡包示例提交给真实 Codex。桌面应用展示 CLI 执行中会话及权限外操作的交互仍需在实际任务中核对。

## HTTP 状态通道与定向同步（1.4.1）

新增随包原生 `CodexStatusHook`，异步生命周期 Hooks 先保存状态文件，再通过带认证的本机 HTTP 通知应用。应用按会话 ID 定向读取并更新；文件监听传递变化路径，已知日志/状态文件使用 50 ms 窗口定向读取，索引发现保留 300 ms 窗口。HTTP 优先于尚未执行的发现扫描。原 `CodexTaskRunner` 保存回执后也主动通知，回执定时器改为 2 秒兜底。

应用自动发布随机端口的本机发现文件；助手连接失败不丢弃已保存的状态。60 秒全量兜底、启动恢复、工作区隔离、旧事件不可复活终态及人工完成勾选规则继续生效。使用 `python3 scripts/install-codex-hooks.py` 合并安装全局配置，再按 Codex 自身流程审核信任；不会自动信任命令。详见 `CODEX-HOOKS.md`。
