# Codex Tasks · Lite

macOS 原生任务小窗。左边选任务，右边显示该任务的多个 Codex 会话，底部回车快速记任务。参考图只指定两栏与底部输入框的布局，视觉沿用完整版本的浅灰侧栏、蓝色强调色、深色文字与圆角白色卡片，无 Tabs、项目、CI/CD、空间切换、设置、运行服务面板或精简模式。

## 分支

- `v1-full`：重写前全部代码和原有验收资料，基线提交 `ad4dd6c`。
- `v1-lite`：本次从零重写的任务版。旧业务模型、服务、Hook、调度器及流水线均已移除。

## 使用

1. 底部输入任务并按回车，获得 `T#01`；关联指令会自动复制到剪贴板。
2. 在任意 Codex 聊天中单独发送一行 `关联任务【T#01】`。多个聊天发送同一任务号，就会在该任务下显示多张会话卡片。
3. 也可点击右上角 `＋`，搜索本机全部会话并关联；已关联其它任务的会话需确认移动。
4. 点击会话卡片，在 Codex 中打开对应聊天。每张卡片保留独立会话 ID 和运行状态；窗口呈现方式由 Codex 客户端决定。
5. `未开始 / 进行中 / 已完成` 手动切换任务状态。会话执行完成不会自动完成任务。
6. 右键会话卡片可解除关联；删除任务仅删除本地任务及关联，不删除 Codex 聊天。

任务标题可直接编辑，回车或失焦保存。点击任务号可再次复制指令。`⌘N` 聚焦快速记录；`⌘⇧空格` 显示／隐藏窗口；关闭窗口后仍可从菜单栏打开。

## 数据

使用全新的关系型 SQLite 数据库：

`~/Library/Application Support/CodexTasks/Lite/tasks.sqlite`

业务表只有 `tasks` 和 `sessions`，`sessions.task_id` 指向任务，一个任务可拥有任意多个会话。解除关联和删除任务后保留未绑定会话的操作时间，防止旧日志重新绑定。任务编号单调递增，不重复使用已删除的编号。

不读取、不迁移、不删除旧版任务数据库或工作区目录表。轻量版从空任务列表开始。bundle ID 保持 `ai.sunkey.floatingworkbench`，正式应用路径保持 `outputs/Codex Tasks.app`。

会话适配器只读 `~/.codex/state_*.sqlite` 及其 `sessions/`、`archived_sessions/` 内的 JSONL，不扫描项目目录，不执行 Git，不更改 Codex 配置。默认列出全部本机会话。FSEvents 触发增量读取，60 秒定时补查；日志解析在后台进行，有总量预算，大日志优先读取尾部再补历史。只接受用户消息中的独立关联指令，忽略助手输出、引用和代码块。

会话状态来自本机日志中的执行事件。缺失日志、无生命周期证据或长时间没有日志活动的运行会话显示“状态未知”。私有日志格式变化时需要更新适配器；任务管理在 Codex 未安装时仍可使用。

## 开发与交付

```sh
./scripts/test.sh
UNIVERSAL=1 RELAUNCH=0 ./scripts/build-app.sh
./scripts/test-window.sh
UNIVERSAL=1 ./scripts/build-app.sh
```

最后一条为正常交付：先校验双架构应用和 ZIP，再关闭本项目旧进程、替换输出并启动新版，确认只有一个正式实例。不会停止 Codex／ChatGPT 本体。

- 应用：`outputs/Codex Tasks.app`
- 压缩包：`outputs/Codex-Tasks-macOS.zip`
- 核心报告：`outputs/lite-core-acceptance.json`
- 原生窗口报告：`outputs/lite-window-acceptance.json`
- 原生渲染预览：`outputs/lite-preview.png`

测试使用临时数据和合成 Codex 索引／日志，不操作真实用户会话。窗口截图中的示例任务只存在于隔离验收目录。支持 Intel / Apple Silicon，最低 macOS 13，应用使用本地 ad-hoc 签名。
