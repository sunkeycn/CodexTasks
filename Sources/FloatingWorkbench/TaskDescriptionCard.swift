import AppKit
import SwiftUI
import WebKit

struct TaskDescriptionCard: View {
    let taskID: Int64
    let save: (Int64, String) -> Bool
    @State private var text: String
    @State private var editing: Bool
    @State private var editorHeight: CGFloat = 80
    @State private var previewHeight: CGFloat = 64

    init(taskID: Int64, details: String, save: @escaping (Int64, String) -> Bool) {
        self.taskID = taskID; self.save = save
        _text = State(initialValue: details)
        _editing = State(initialValue: details.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("任务描述").font(.system(size: 12, weight: .semibold))
                Text("Markdown").font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Button(editing ? "预览" : "编辑") { editing.toggle() }
                    .font(.system(size: 12)).foregroundColor(.accentColor)
                    .accessibilityIdentifier("task-description-toggle")
            }
            if editing {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("添加任务描述，支持 Markdown…")
                            .font(.system(size: 13)).foregroundColor(.secondary)
                            .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                    }
                    GrowingMarkdownEditor(text: $text, height: $editorHeight)
                        .frame(height: editorHeight)
                        .accessibilityIdentifier("task-description-editor")
                }
            } else if text.isEmpty {
                Text("暂无描述").font(.system(size: 13)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
            } else {
                MarkdownPreview(text: text, height: $previewHeight)
                    .frame(height: previewHeight)
                    .accessibilityIdentifier("task-description-preview")
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white).cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.05), lineWidth: 1))
        // Save each edit so switching tasks, closing the window or quitting never drops a draft.
        .onChange(of: text) { _ = save(taskID, $0) }
    }
}

struct GrowingMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat

    final class TextView: NSTextView {
        var resized: ((CGFloat) -> Void)?
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            measure()
        }
        func measure() {
            guard let layoutManager, let textContainer, bounds.width > 0 else { return }
            layoutManager.ensureLayout(for: textContainer)
            let measured = max(80, ceil(max(layoutManager.usedRect(for: textContainer).maxY, layoutManager.extraLineFragmentRect.maxY) + textContainerInset.height * 2))
            resized?(measured)
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingMarkdownEditor
        init(_ parent: GrowingMarkdownEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? TextView else { return }
            parent.text = view.string; view.measure()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> TextView {
        let view = TextView()
        view.isRichText = false; view.importsGraphics = false
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.allowsUndo = true; view.drawsBackground = false
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = NSColor(calibratedRed: 0.15, green: 0.19, blue: 0.24, alpha: 1)
        view.textContainerInset = NSSize(width: 0, height: 8)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.setAccessibilityLabel("任务描述 Markdown 编辑区")
        view.setAccessibilityIdentifier("task-description-editor")
        view.delegate = context.coordinator
        return view
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TextView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: height)
    }
    func updateNSView(_ view: TextView, context: Context) {
        context.coordinator.parent = self
        view.resized = { value in
            DispatchQueue.main.async { if abs(height - value) > 0.5 { height = value } }
        }
        if view.string != text { view.string = text }
        view.measure()
    }
}

struct MarkdownPreview: NSViewRepresentable {
    let text: String
    @Binding var height: CGFloat

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MarkdownPreview
        var ready = false
        var renderedText: String?
        init(_ parent: MarkdownPreview) { self.parent = parent }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let value = message.body as? Double, value.isFinite else { return }
            let measured = CGFloat(max(40, ceil(value)))
            if abs(parent.height - measured) > 0.5 { parent.height = measured }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; render(in: webView) }
        func render(in view: WKWebView) {
            guard ready, renderedText != parent.text else { return }
            renderedText = parent.text
            let json = String(data: try! JSONEncoder().encode(parent.text), encoding: .utf8)!
            view.evaluateJavaScript("renderMarkdown(\(json))", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            } else { decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel) }
        }
    }
    /// Send vertical wheel events to the detail pane instead of trapping them in WebKit.
    final class PreviewView: WKWebView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            if hit != nil, NSApp.currentEvent?.type == .scrollWheel { return self }
            return hit
        }
        override func scrollWheel(with event: NSEvent) {
            if let scrollView = enclosingScrollView { scrollView.scrollWheel(with: event) }
            else { nextResponder?.scrollWheel(with: event) }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let resources = Bundle.main.resourceURL?.appendingPathComponent("CodexTasksLite_FloatingWorkbench.bundle")
        let bundle = resources.flatMap { Bundle(url: $0) } ?? Bundle.module
        func script(_ name: String) -> String {
            guard let url = bundle.url(forResource: name, withExtension: "js", subdirectory: "Markdown"), let source = try? String(contentsOf: url) else { return "" }
            return source
        }
        let javascript = script("marked") + "\n" + script("purify") + "\n" + """
        const body = document.getElementById('content');
        function reportHeight() { window.webkit.messageHandlers.height.postMessage(body.getBoundingClientRect().height); }
        function renderMarkdown(text) {
            body.innerHTML = DOMPurify.sanitize(marked.parse(text, {gfm:true}), {USE_PROFILES:{html:true}, FORBID_TAGS:['style','form','button']});
            body.querySelectorAll('a').forEach(a => a.rel = 'noopener noreferrer');
            requestAnimationFrame(reportHeight);
        }
        new ResizeObserver(reportHeight).observe(body);
        document.addEventListener('load', reportHeight, true);
        """
        configuration.userContentController.addUserScript(WKUserScript(source: javascript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController.add(context.coordinator, name: "height")
        let view = PreviewView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(Self.html, baseURL: nil)
        return view
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: height)
    }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.parent = self; context.coordinator.render(in: view) }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "height")
        view.navigationDelegate = nil
    }
    private static let html = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'">
    <style>
    html,body{margin:0;padding:0;background:transparent;overflow:hidden;color:#26313d;font:13px/1.65 -apple-system,BlinkMacSystemFont,sans-serif;overflow-wrap:anywhere}
    #content{display:flow-root} #content>:first-child{margin-top:0} #content>:last-child{margin-bottom:0}
    p,ul,ol,blockquote,pre,table{margin:0 0 10px} h1,h2,h3,h4,h5,h6{line-height:1.35;margin:16px 0 8px;font-weight:650} h1{font-size:22px}h2{font-size:19px}h3{font-size:16px}h4,h5,h6{font-size:14px}
    ul,ol{padding-left:22px}li>p{margin-bottom:4px}a{color:#2e64db;text-decoration:none}a:hover{text-decoration:underline}
    code{font:12px/1.6 ui-monospace,SFMono-Regular,monospace;background:#f0f2f6;padding:2px 4px;border-radius:4px}pre{background:#f3f5f8;padding:12px;border-radius:7px;white-space:pre-wrap}pre code{padding:0;background:none}
    blockquote{margin-left:0;padding:3px 12px;border-left:3px solid #b9caef;color:#647080}blockquote p:last-child{margin-bottom:0}
    table{display:block;overflow-x:auto;border-collapse:collapse}th,td{border:1px solid #e3e7ec;padding:6px 10px}th{background:#f3f5f8}img{max-width:100%;height:auto;border-radius:6px}hr{border:0;border-top:1px solid #e3e7ec;margin:14px 0}
    </style></head><body><main id="content"></main></body></html>
    """
}
