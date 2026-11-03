# Lite 数据与交互约定

## 业务对象

`tasks(id, title, status, created_at, parent_id, unread_completion)`：任务唯一编号即自增主键。状态只接受 `todo / doing / done`，由用户修改。

`sessions(id, task_id, title, status, updated_at, bound_at)`：Codex 会话 UUID 是主键。一个会话最多绑定一个任务，一个任务允许多个会话。`task_id` 允许为空，解除或删除后的会话用 `bound_at` 阻止旧指令覆盖用户操作。没有项目、空间、分支、Run、流水线、通知、设置表。

- `parent_id` 为空即主任务，否则只能指向主任务；数据库外键和触发器限制为一层。快照按主任务及其子任务分组，父子状态与会话关联独立。删除父任务时 `ON DELETE SET NULL` 保留子任务，移到最外层。
- schema 1 → 2 → 3 在写事务内增量增加父关系、索引、层级触发器和完成未读标记，不重建库，不修改旧任务或会话。旧版 Lite 程序不支持 schema 3。
- SQLite WAL + FULL；写操作使用 `BEGIN IMMEDIATE`，快照读取在一个事务内完成。
- 数据库使用独立 `application_id` 与 `user_version`。旧版、未知或未来 schema 均拒绝覆盖。
- `unread_completion` 仅在已关联且归属不变的会话由 running → completed 时置位，更新和会话状态写入同一事务。过时状态不覆盖较新状态；历史已完成会话初次关联不提醒。点击任务显式清除；重复完成观察不重新置位。
- 侧栏宽度和折叠任务 ID 存 UserDefaults；隔离验收使用独立偏好。折叠父任务汇总子任务未读，不替子任务清除；创建子任务自动展开父任务。
- 自动关联要求：用户消息独立行、任务存在、指令不早于任务创建、指令晚于最后绑定／解除时间。
- 同一任务再次关联其它会话时只新增该会话，不替换已有会话。
- 切换任务的人工状态不会更改任何会话的运行状态，反之亦然。
- 删除任务保留会话解绑时间；不修改 Codex 数据。

## 模块

- `LiteCore/TaskStore.swift`：唯一的本地任务数据写入入口。
- `LiteCore/CodexReader.swift`：只读全部本机会话元数据和受限路径内的日志，后台增量解析。
- `FloatingWorkbench/AppModel.swift`：异步刷新、选择和用户动作。
- `FloatingWorkbench/Views.swift`：单屏任务列表、详情、会话卡片和快速记录。
- `FloatingWorkbench/TaskSplitView.swift`：原生分栏托管，内容变化和弹窗关闭不重置拖动后的宽度。
- `FloatingWorkbench/AppHost.swift`：任务窗口、独立设置窗口、菜单栏、快捷键和隔离窗口验收。
- `FloatingWorkbench/CodexMonitor.swift`：观察 Codex 索引、日志和本地 Hooks 事件；不观察 SQLite SHM，避免读取反馈循环。

## 界面

参考草图只表达布局，视觉沿用 v1-full 的原有风格：浅灰侧栏、蓝色强调色、深色文字、圆角白色卡片和淡色状态标签。不得将草图红线当成视觉规范。主体只有两栏，原生分隔线可拖动，首次左宽 300，重启恢复上次宽度。底部输入框横跨两栏，仅通过回车新建。

左侧隐藏任务编号，卡片全部留白区域可点击切换，状态圈与折叠箭头单独响应；子任务缩进一层。父任务右侧箭头折叠／展开，完成未读红点显示在卡片右侧。左侧标题最多三行并提供全文悬停提示。详情任务编号紧挨任务名；原圆形加号的位置放“＋ 子任务”。第二行状态组在左，删除图标与“关联会话”在右，关联按钮最右对齐。会话弹窗支持连续多选，点击外部收起。


没有原版模块、顶部 Tabs、工作空间入口、服务运行状态、同步按钮或外部执行调度。连接设置独立从 macOS 菜单打开，不占用任务主体布局。

## 可选连接与 Hooks

- `IntegrationSettings`：当前用户的 Codex 目录、应用位置及读取间隔；独立 JSON 不增加业务表。
- `HookInstaller`：合并配置、备份、稳定路径部署及仅移除本应用 Hooks；不更改 Codex 信任记录。
- `CodexTasksHook`：双架构原生命令，接收 stdin，仅写入本地元数据事件；任何解析错误均静默成功退出。
- `HookEventStore`：每会话锁、原子写、乱序过滤；与索引观察按时间合并，最终仍通过 TaskStore 统一协调关联与完成提醒。
- 保存设置会使旧后台读取失效，避免更换连接后旧回调写入过时关联。

详细路径审计、配置边界与迁移说明见 `CONFIGURATION.md` 及 README。
