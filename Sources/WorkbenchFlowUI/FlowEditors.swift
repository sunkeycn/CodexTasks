import SwiftUI
import WorkbenchCore

@MainActor struct FlowBindingEditor: View {
    @ObservedObject var model: FlowWorkbenchModel
    let definition: PipelineDefinition
    @State private var binding: PipelineBinding
    @State private var saved = false
    init(model: FlowWorkbenchModel, definition: PipelineDefinition) {
        self.model = model; self.definition = definition
        var value = model.binding ?? PipelineBinding(pipelineID: definition.id)
        if value.definitionRevision != definition.revision { value.reviewed = false }
        value.definitionRevision = definition.revision
        _binding = State(initialValue: value)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("本地关联与参数定义").font(.title3.bold())
                Text("保存只更新工作台。请按实际流水线、脚本与资源补配，不能用本地环境名称代替远端部署逻辑。").font(.caption).foregroundColor(.secondary)
                if !definition.detailLoaded { Text("请先读取最新定义。").foregroundColor(.orange) }
                ForEach(definition.sources) { source in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("代码源 \(source.id)").font(.headline)
                        Text(source.repo).font(.caption).textSelection(.enabled)
                        let candidates = FlowIdentity.projectCandidates(source: source, snapshot: model.localSnapshot)
                        if !candidates.isEmpty { Text("仓库匹配建议：\(candidates.map(\.name).joined(separator: "、"))；请确认后勾选。").font(.caption).foregroundColor(.secondary) }
                        ForEach(model.localSnapshot.projects) { project in
                            Toggle(project.name, isOn: Binding(get: { binding.sourceProjects[source.id]?.contains(project.id) == true }, set: { checked in
                                var ids = binding.sourceProjects[source.id] ?? []
                                if checked { if !ids.contains(project.id) { ids.append(project.id) } } else { ids.removeAll { $0 == project.id } }
                                binding.sourceProjects[source.id] = ids
                            })).font(.caption)
                        }
                        if model.localSnapshot.projects.isEmpty { Text("当前工作区暂无项目；可先保留目录，添加已有授权项目后再关联。").font(.caption).foregroundColor(.orange) }
                    }.padding(12).background(Color.gray.opacity(0.05)).cornerRadius(8)
                }
                Picker("影响类型", selection: $binding.mode) { Text("固定环境（展示全部目标）").tag(FlowEnvironmentMode.fixed); Text("运行时选择").tag(FlowEnvironmentMode.runtime); Text("纯 CI，不涉及部署").tag(FlowEnvironmentMode.ci) }
                if binding.mode != .ci {
                    TextField("真实环境变量键（固定且无变量时可空）", text: $binding.environmentKey)
                    Text("同一运行变量值可以对应多个目标，预览将全部列出。除 dev/test/daily/pre 外全部按生产，当前生产提交不可用。").font(.caption).foregroundColor(.secondary)
                    ForEach($binding.targets) { $target in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { TextField("环境原名，如 test / eu", text: $target.environment); TextField("真实运行变量值", text: $target.value); Button("移除") { binding.targets.removeAll { $0.id == target.id } } }
                            TextField("主机 / 集群 / 命名空间 / 应用 / 服务（列出全部资源）", text: $target.resources)
                            TextField("具体动作", text: $target.action)
                            TextField("影响面", text: $target.impact)
                            TextField("识别依据、脚本位置或资源来源", text: $target.evidence)
                            if target.isProduction { Text("按生产处理：不能在本应用提交。").font(.caption).foregroundColor(.orange) }
                        }.padding(12).background(Color.gray.opacity(0.05)).cornerRadius(8)
                    }
                    Button("添加目标 / 环境映射") { binding.targets.append(FlowTarget()) }
                } else { Text("仅在人工核对流程与脚本确认完全不部署后选择。CI 不是可绕过生产校验的环境别名。").font(.caption).foregroundColor(.orange) }
                Divider()
                Text("运行变量").font(.headline)
                Text("仅补配流水线允许覆盖的真实变量。保密默认值不落盘；运行表单可保留服务器默认值或显式提交空值。").font(.caption).foregroundColor(.secondary)
                ForEach($binding.variables) { $variable in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { TextField("变量键", text: $variable.key); TextField("显示名", text: $variable.label); Button("移除") { binding.variables.removeAll { $0.id == variable.id } } }
                        Picker("类型", selection: $variable.kind) { Text("字符串").tag(FlowVariableKind.string); Text("枚举").tag(FlowVariableKind.enumeration); Text("私密").tag(FlowVariableKind.secret) }
                        if variable.kind == .enumeration { TextField("选项真实值，英文逗号分隔", text: Binding(get: { variable.options.joined(separator: ",") }, set: { variable.options = $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } })) }
                        if variable.kind != .secret { TextField("默认值（与远端配置一致）", text: $variable.defaultValue) }
                        HStack { Toggle("必填", isOn: $variable.required); Toggle("允许运行时覆盖", isOn: $variable.editable) }.font(.caption)
                    }.padding(12).background(Color.gray.opacity(0.05)).cornerRadius(8)
                    .onChange(of: variable.kind) { kind in if kind == .secret { if let i = binding.variables.firstIndex(where: { $0.id == variable.id }) { binding.variables[i].defaultValue = "" } } }
                }
                Button("添加运行变量") { binding.variables.append(FlowVariable()) }
                Divider()
                Text("制品选择").font(.headline)
                ForEach($binding.artifacts) { $artifact in
                    VStack(spacing: 8) {
                        HStack { TextField("显示名", text: $artifact.label); Button("移除") { binding.artifacts.removeAll { $0.id == artifact.id } } }
                        Picker("类型", selection: $artifact.kind) { Text("上游流水线实例").tag(FlowArtifactKind.runningPipelineArtifacts); Text("ACR 镜像").tag(FlowArtifactKind.runningAcrArtifacts); Text("Packages").tag(FlowArtifactKind.runningPackagesArtifacts) }
                        TextField("真实制品源键 / 上游流水线 ID", text: $artifact.key)
                    }.padding(12).background(Color.gray.opacity(0.05)).cornerRadius(8)
                }
                Button("添加制品源") { binding.artifacts.append(FlowArtifact()) }
                Divider()
                TextField("配置核对依据（流程/脚本、变量及目标完整性）", text: $binding.evidence)
                Toggle("我已核对当前定义的全部代码源、可运行变量、制品与部署目标，无遗漏的部署阶段", isOn: $binding.reviewed).font(.caption)
                HStack { Button("保存本地配置") { model.saveBinding(binding); saved = model.binding == binding }.buttonStyle(.borderedProminent).disabled(model.busy || !definition.detailLoaded || !binding.reviewed); if saved { Text("已保存").font(.caption).foregroundColor(.secondary) } }
            }.textFieldStyle(.roundedBorder).padding(16).background(.white).cornerRadius(10)
        }
        .onChange(of: binding) { _ in saved = false }
        .onChange(of: binding.mode) { mode in if mode == .ci { binding.targets = []; binding.environmentKey = "" } }
    }
}

@MainActor struct FlowRunEditor: View {
    @ObservedObject var model: FlowWorkbenchModel
    let definition: PipelineDefinition
    @State private var draft: FlowRunDraft
    @State private var acknowledged = false
    init(model: FlowWorkbenchModel, definition: PipelineDefinition) {
        self.model = model; self.definition = definition
        var draft = FlowRunDraft()
        for source in definition.sources { draft.codes[source.id] = FlowCodeChoice(value: source.branch) }
        if let binding = model.binding { draft.targetID = binding.targets.first?.id }
        _draft = State(initialValue: draft)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("运行配置").font(.title3.bold())
                if let binding = model.binding, definition.detailLoaded {
                    if !binding.reviewed || binding.definitionRevision != definition.revision { Text("关联尚未核对或定义已变化，请先重新配置。").foregroundColor(.orange) }
                    if model.connection?.readOnly == true { Text("当前连接为本地只读模式；需新建允许运行的连接。").font(.caption).foregroundColor(.orange) }
                    ForEach(definition.blockers, id: \.self) { Text($0).foregroundColor(.orange) }
                    if binding.mode == .runtime {
                        Picker("目标环境", selection: $draft.targetID) { ForEach(binding.targets) { target in Text("\(target.environment) · \(target.value)").tag(Optional(target.id)) } }
                    } else { Text(binding.mode == .ci ? "纯 CI，不涉及部署" : "固定环境：\(binding.targets.map(\.environment).joined(separator: "、"))").font(.headline) }
                    Text("代码源").font(.headline)
                    ForEach(definition.sources) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(source.repo).font(.caption).textSelection(.enabled)
                            HStack {
                                Picker("类型", selection: Binding(get: { draft.codes[source.id]?.isTag ?? false }, set: { draft.codes[source.id]?.isTag = $0 })) { Text("分支").tag(false); Text("Tag").tag(true) }.frame(width: 160)
                                TextField("手动输入（未查询候选）", text: Binding(get: { draft.codes[source.id]?.value ?? "" }, set: { draft.codes[source.id] = FlowCodeChoice(value: $0, isTag: draft.codes[source.id]?.isTag ?? false) }))
                            }
                        }
                    }
                    Text("按名称运行，未锁定 commit SHA。Tag 与制品版本名也不等于不可变版本。").font(.caption).foregroundColor(.orange)
                    ForEach(binding.variables) { variable in variableField(variable) }
                    ForEach(binding.artifacts) { artifact in
                        TextField("\(artifact.label.isEmpty ? artifact.key : artifact.label) · 已知版本（未查询验证）", text: Binding(get: { draft.artifacts[artifact.id] ?? "" }, set: { draft.artifacts[artifact.id] = $0 }))
                    }
                    TextField("运行备注（不保存到本地回执）", text: $draft.comment)
                    Picker("关联任务", selection: $draft.taskID) { Text("不关联任务").tag(Optional<UUID>.none); ForEach(model.localSnapshot.tasks) { Text("\($0.displayNumber) · \($0.title)").tag(Optional($0.id)) } }
                    Text("实例状态不会修改任务的人工完成状态。").font(.caption).foregroundColor(.secondary)
                    Button("读取最新定义并生成范围预览") { model.prepare(draft) }.buttonStyle(.borderedProminent).disabled(model.busy || !model.readScopeAuthorized || model.connection?.readOnly == true || !definition.blockers.isEmpty || !binding.reviewed)
                    if let preview = model.preview {
                        Divider()
                        Text("核对本次执行范围").font(.title3.bold())
                        Text("Flow：\(preview.pipelineName) #\(preview.pipelineID)\n项目：\(preview.projects.joined(separator: "、"))\n配置版本：\(preview.revision.prefix(16))").font(.caption).textSelection(.enabled)
                        ForEach(preview.targets) { target in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("环境：\(target.environment) · 实际值：\(target.value)").font(.headline)
                                Text("主机 / 资源：\(target.resources)\n动作：\(target.action)\n影响面：\(target.impact)\n依据：\(target.evidence)").font(.caption)
                            }.padding(12).background(Color.orange.opacity(0.06)).cornerRadius(8)
                        }
                        if preview.targets.isEmpty { Text("影响类型：已人工核对的纯 CI，无部署目标").font(.caption) }
                        Text(preview.redactedParameters).font(.caption.monospaced()).textSelection(.enabled)
                        Text(preview.versionWarning).font(.caption).foregroundColor(.orange)
                        Text("有效至 \(preview.expiresAt.formatted(date: .omitted, time: .standard))。任何参数、关联或定义变化后需重新预览。").font(.caption2).foregroundColor(.secondary)
                        Toggle("我同意以上完整范围及本次参数，确认执行一次", isOn: $acknowledged).font(.callout)
                        Button("确认运行一次") { model.submit(draft, acknowledged: acknowledged); acknowledged = false }.buttonStyle(.borderedProminent).disabled(!acknowledged || model.busy || !model.readScopeAuthorized)
                    }
                } else { Text("请先读取定义并完成关联配置；无法解析的参数不能静默忽略。").foregroundColor(.secondary) }
            }.textFieldStyle(.roundedBorder).padding(16).background(.white).cornerRadius(10)
        }
        .onChange(of: draft) { _ in model.preview = nil; acknowledged = false; Task { await model.coordinator.invalidate() } }
        .onDisappear { draft.variables = [:]; draft.artifacts = [:]; model.preview = nil; Task { await model.coordinator.invalidate() } }
    }
    private func variableField(_ variable: FlowVariable) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(variable.label.isEmpty ? variable.key : variable.label) · \(variable.key)\(variable.required ? " · 必填" : "")").font(.caption.bold())
            if variable.editable {
                Toggle("本次覆盖（关闭则保留服务器默认值）", isOn: Binding(get: { draft.variables[variable.key] != nil }, set: { enabled in if enabled { draft.variables[variable.key] = variable.kind == .secret ? "" : variable.defaultValue } else { draft.variables[variable.key] = nil } })).font(.caption)
                if draft.variables[variable.key] != nil {
                    let value = Binding(get: { draft.variables[variable.key] ?? "" }, set: { draft.variables[variable.key] = $0 })
                    if variable.kind == .secret { SecureField("仅本次使用，不写入数据库", text: value) }
                    else if variable.kind == .enumeration { Picker("选择", selection: value) { Text("选择值").tag(""); ForEach(variable.options, id: \.self) { Text($0).tag($0) } } }
                    else { TextField("可显式提交空字符串", text: value) }
                }
            } else { Text("不可覆盖，保留服务器值").font(.caption).foregroundColor(.secondary) }
        }
    }
}

@MainActor struct FlowHistoryView: View {
    @ObservedObject var model: FlowWorkbenchModel
    let definition: PipelineDefinition
    @State private var jobID = ""
    @State private var reconcileIDs: [UUID: String] = [:]
    @State private var reconcileAcknowledged: Set<UUID> = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("运行记录").font(.title3.bold()); Spacer(); Button("读取运行记录") { model.loadRuns() }.disabled(model.busy || !model.readScopeAuthorized) }
                if let error = model.runSyncErrors[definition.id] { Text(error).font(.caption).foregroundColor(.orange) }
                let attempts = model.visibleAttempts.filter { $0.preview.pipelineID == definition.id }
                ForEach(attempts.reversed()) { attempt in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(attempt.state == .accepted ? "本次提交已接收 · 实例 #\(attempt.remoteID ?? "")" : "提交结果未知 · 禁止重复提交").font(.headline).foregroundColor(attempt.state == .accepted ? .primary : .orange)
                        Text("本地确认 \(attempt.id.uuidString.prefix(8)) · \(attempt.createdAt.formatted())").font(.caption)
                        Text("当次范围：\(attempt.preview.projects.joined(separator: "、")) · \(attempt.preview.targets.map(\.environment).joined(separator: "、"))").font(.caption)
                        ForEach(attempt.preview.targets) { target in Text("\(target.environment) | \(target.resources) | \(target.action) | \(target.impact)").font(.caption2) }
                        if attempt.state != .accepted {
                            Text("请在云效人工核对；不会仅按备注或相近时间绑定实例。中断时的提交也按结果未知处理。").font(.caption).foregroundColor(.secondary)
                            TextField("已人工核对的云效实例 ID", text: Binding(get: { reconcileIDs[attempt.id] ?? "" }, set: { reconcileIDs[attempt.id] = $0; reconcileAcknowledged.remove(attempt.id) }))
                            Toggle("我已人工确认该实例唯一对应本次提交", isOn: Binding(get: { reconcileAcknowledged.contains(attempt.id) }, set: { if $0 { reconcileAcknowledged.insert(attempt.id) } else { reconcileAcknowledged.remove(attempt.id) } })).font(.caption)
                            Button("核对实例并关联（不执行 Flow）") { model.reconcile(attempt, runID: reconcileIDs[attempt.id] ?? "", humanConfirmed: reconcileAcknowledged.contains(attempt.id)) }.disabled(model.busy || !model.readScopeAuthorized || !reconcileAcknowledged.contains(attempt.id) || (reconcileIDs[attempt.id] ?? "").isEmpty)
                        }
                    }.padding(12).background(Color.orange.opacity(0.06)).cornerRadius(8)
                }
                if let runs = model.cache?.runs[definition.id] {
                    if runs.isEmpty { Text("从未运行").foregroundColor(.secondary) }
                    ForEach(runs) { run in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text("实例 #\(run.id)").font(.headline); Text(run.statusLabel).font(.caption); Spacer(); Button("读取详情 / 核对状态") { model.loadRun(run) }.disabled(model.busy || !model.readScopeAuthorized) }
                            Text("触发人：\(run.creator.isEmpty ? "未提供" : run.creator) · \(run.startedAt?.formatted() ?? "时间未提供")").font(.caption).foregroundColor(.secondary)
                            ForEach(Array(run.stages.enumerated()), id: \.offset) { _, text in Text(text).font(.caption) }
                            Text(run.actualVersions.isEmpty ? "实际 commit SHA 尚未提供，不能用分支名代替。" : run.actualVersions.joined(separator: "\n")).font(.caption2).foregroundColor(.secondary)
                            ForEach(run.jobs) { job in
                                HStack { Text("\(job.name) · \(job.status)").font(.caption); Spacer(); Button("读取任务日志") { model.getLog(run: run, jobID: job.id) }.disabled(model.busy || !model.readScopeAuthorized) }
                            }
                            HStack { TextField("云效任务 Job ID（未加载任务列表时手动输入）", text: $jobID); Button("读取此任务日志") { model.getLog(run: run, jobID: jobID) }.disabled(jobID.isEmpty || model.busy || !model.readScopeAuthorized) }
                        }.padding(12).background(Color.gray.opacity(0.05)).cornerRadius(8)
                    }
                } else { Text("运行记录尚未加载，列表接口不保证含状态，需要另读实例详情。").font(.caption).foregroundColor(.secondary) }
                if !model.log.isEmpty { Text("本次读取的任务日志（仅内存）").font(.headline); Text(model.log).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.textFieldStyle(.roundedBorder).padding(16).background(.white).cornerRadius(10)
        }
        .onDisappear { model.log = "" }
    }
}
