# Lite 数据与交互约定

## 业务对象

`tasks(id, title, status, created_at)`：任务唯一编号即自增主键。状态只接受 `todo / doing / done`，由用户修改。

`sessions(id, task_id, title, status, updated_at, bound_at)`：Codex 会话 UUID 是主键。一个会话最多绑定一个任务，一个任务允许多个会话。`task_id` 允许为空，解除或删除后的会话用 `bound_at` 阻止旧指令覆盖用户操作。没有项目、空间、分支、Run、流水线、通知、设置表。

- SQLite WAL + FULL；写操作使用 `BEGIN IMMEDIATE`，快照读取在一个事务内完成。
- 数据库使用独立 `application_id` 与 `user_version`。旧版、未知或未来 schema 均拒绝覆盖。
- 自动关联要求：用户消息独立行、任务存在、指令不早于任务创建、指令晚于最后绑定／解除时间。
- 同一任务再次关联其它会话时只新增该会话，不替换已有会话。
- 切换任务的人工状态不会更改任何会话的运行状态，反之亦然。
- 删除任务保留会话解绑时间；不修改 Codex 数据。

## 模块

- `LiteCore/TaskStore.swift`：唯一的本地任务数据写入入口。
- `LiteCore/CodexReader.swift`：只读全部本机会话元数据和受限路径内的日志，后台增量解析。
- `FloatingWorkbench/AppModel.swift`：异步刷新、选择和用户动作。
- `FloatingWorkbench/Views.swift`：单屏任务列表、详情、会话卡片和快速记录。
- `FloatingWorkbench/AppHost.swift`：唯一原生窗口、菜单栏、快捷键和隔离窗口验收。
- `FloatingWorkbench/CodexMonitor.swift`：观察 Codex 索引和日志；不观察 SQLite SHM，避免读取反馈循环。

## 界面

参考草图只表达布局，视觉沿用 v1-full 的原有风格：浅灰侧栏、蓝色强调色、深色文字、圆角白色卡片和淡色状态标签。不得将草图红线当成视觉规范。主体只有两栏，使用原生可拖动分隔线，底部输入框横跨两栏，仅通过回车新建。左侧标题最多三行并提供全文悬停提示，右侧标题自动换行。右侧标题区域显示任务名与编号、三个人工状态及删除动作，右上角圆形加号打开支持连续多选的会话弹窗；勾选保留列表位置，不关闭弹窗，再点可解除，点击弹窗外部收起。每张会话卡片只显示名称和运行状态，点击打开会话，右键解除关联。

没有原版模块、顶部 Tabs、工作空间入口、应用设置、服务运行状态、同步按钮、紧凑窗口或外部执行调度。
