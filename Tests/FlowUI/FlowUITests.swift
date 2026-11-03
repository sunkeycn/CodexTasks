#if DEBUG
import AppKit
import SwiftUI
import WorkbenchCore
@testable import WorkbenchFlowUI

struct UITransport: FlowHTTPTransport {
    func send(_ request: URLRequest) async throws -> FlowHTTPResponse {
        let raw: [String: Any] = ["name": "测试服务 · 构建并部署", "pipelineConfig": ["flow": "schema: tb\npipeline: []", "settings": "{}", "sources": [["sign": "code", "type": "Codeup", "data": ["repo": "https://example.com/team/app.git", "branch": "main"]]]]]
        return FlowHTTPResponse(data: try JSONSerialization.data(withJSONObject: raw))
    }
}
struct UIAssertion: Error { var message: String }
func verify(_ value: Bool, _ message: String) throws { if !value { throw UIAssertion(message: message) } }
func unwrap<T>(_ value: T?) throws -> T { guard let value else { throw UIAssertion(message: "expected value") }; return value }
final class FlowUITests {
    @MainActor func testNativeFlowScreensWithIsolatedFixtures() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flow-ui-fixtures-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try WorkbenchService(databaseURL: directory.appendingPathComponent("state.sqlite"))
        let model = FlowWorkbenchModel(service: service)
        try verify(model.connection == nil, "new connection")
        try verify(!model.readScopeAuthorized, "read scope must be explicit")
        try render(FlowWorkbenchView(service: service), name: "01-未连接", width: 674)
        var c = YunxiaoConnection(); c.organization = "fixture-org"; c.account = "离线测试账号"; c.readOnly = false
        try service.saveFlowConnection(c)
        let project = try service.createProject(name: "示例测试服务", repository: "git@example.com:team/app.git")
        _ = try service.createTask(title: "CI/CD 离线验收任务")
        let api = YunxiaoAPI(connection: c, token: "fake-token", transport: UITransport())
        let definition = try await api.getPipeline("1001")
        var second = PipelineDefinition(id: "1002", name: "尚未关联的流水线")
        second.available = false
        try service.cacheFlowCatalog(connectionID: c.id, definitions: [definition, second])
        try service.setFlowFavorite(connectionID: c.id, pipelineID: "1001", favorite: true)
        var binding = PipelineBinding(pipelineID: definition.id); binding.definitionRevision = definition.revision
        binding.sourceProjects = ["code": [project.id]]; binding.environmentKey = "DEPLOY_ENV"; binding.evidence = "隔离 fixtures，非真实资源"; binding.reviewed = true
        var target = FlowTarget(); target.environment = "test"; target.value = "testing"; target.resources = "test-cluster / test-app"; target.action = "构建并滚动更新"; target.impact = "测试服务短暂更新"; target.evidence = "离线用例"
        binding.targets = [target]
        var variable = FlowVariable(); variable.key = "CHANNEL"; variable.label = "渠道"; variable.kind = .enumeration; variable.options = ["daily", "stable"]; variable.defaultValue = "daily"; binding.variables = [variable]
        try service.saveFlowBinding(connectionID: c.id, binding: binding)
        model.reload(); model.selectedID = "1001"
        try render(FlowWorkbenchView(service: service), name: "02-完整目录", width: 674)
        try render(FlowBindingEditor(model: model, definition: definition), name: "03-关联配置", width: 674)
        try render(FlowRunEditor(model: model, definition: definition), name: "04-运行参数", width: 674)
        var draft = FlowRunDraft(); draft.codes["code"] = FlowCodeChoice(value: "main"); draft.targetID = target.id
        model.preview = try await model.coordinator.prepare(api: api, pipelineID: definition.id, draft: draft)
        try render(FlowRunEditor(model: model, definition: definition), name: "05-范围确认", width: 674, height: 1150)
        var remote = FlowRemoteRun(id: "7", pipelineID: definition.id); remote.status = "RUNNING"; remote.creator = "fixture-account"; remote.stages = ["构建 · SUCCESS", "部署测试服务 · RUNNING"]
        try service.cacheFlowRuns(connectionID: c.id, pipelineID: definition.id, runs: [remote]); model.reload()
        try render(FlowHistoryView(model: model, definition: definition), name: "06-实例与阶段", width: 674)
        model.chooseConnection(c.id)
        try verify(!model.readScopeAuthorized, "read scope must be explicit")
        try verify(model.preview == nil, "confirmation invalidated")
        try verify(model.selectedID == nil, "selection cleared")
        model.stop()
    }
    @MainActor private func render<V: View>(_ root: V, name: String, width: CGFloat, height: CGFloat = 760) throws {
        let host = NSHostingView(rootView: root.frame(width: width, height: height).background(Color(red: 0.975, green: 0.976, blue: 0.98)).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        try verify(host.frame.width == width, "native view width")
        let image = try unwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let data = try unwrap(image.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CICD_UI_OUTPUT"] ?? FileManager.default.currentDirectoryPath + "/outputs/cicd-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"))
        window.close()
    }
}

@main struct FlowUIAcceptance {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await FlowUITests().testNativeFlowScreensWithIsolatedFixtures(); print("PASS native CI/CD screens: 6 screenshots; fixture-only; no Keychain or real network"); exit(0) }
            catch { print("FAIL CI/CD native UI: \(error)"); exit(1) }
        }
        app.run()
    }
}

#else
import Foundation
@main struct FlowUIAcceptance { static func main() { print("Run FlowUIAcceptance in debug configuration."); exit(2) } }
#endif
