import AppKit
import WebKit

@MainActor
func runMarkdownAcceptance(in root: NSView) -> [String: Bool] {
    func find(_ view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { find($0) }.first
    }
    guard let web = find(root) else { return ["markdownPreviewMounted": false] }
    var result: Any?
    var finished = false
    let script = #"""
    (() => {
        const rendered = document.getElementById('content');
        const dirty = '<img src="x" onerror="alert(1)"><script>alert(2)</script><a href="javascript:alert(3)">bad</a>';
        const clean = document.createElement('div'); clean.innerHTML = DOMPurify.sanitize(dirty);
        const fixture = document.createElement('div');
        fixture.innerHTML = DOMPurify.sanitize(marked.parse('## Heading\n\n- **bold**\n\n|a|b|\n|-|-|\n|c|d|\n\n```swift\nlet x = 1\n```'));
        return {
            markdownPreviewMounted: true,
            markdownBundledRendererLoaded: typeof marked.parse === 'function' && typeof DOMPurify.sanitize === 'function',
            markdownRendersTaskDescription: rendered.querySelector('h2')?.textContent === '目标',
            markdownHeadingListTableCode: !!fixture.querySelector('h2') && !!fixture.querySelector('li strong') && !!fixture.querySelector('table') && !!fixture.querySelector('pre code'),
            markdownRemovesExecutableHTML: !clean.querySelector('script,[onerror],a[href^="javascript:"]'),
            markdownHeightFitsContent: Math.abs(rendered.getBoundingClientRect().height - innerHeight) < 2
        };
    })()
    """#
    let deadline = Date().addingTimeInterval(4)
    repeat {
        finished = false
        web.evaluateJavaScript(script) { value, _ in result = value; finished = true }
        while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        if let checks = result as? [String: Bool], checks.values.allSatisfy({ $0 }) { return checks }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        root.layoutSubtreeIfNeeded()
    } while Date() < deadline
    return result as? [String: Bool] ?? ["markdownPreviewEvaluation": false]
}

/// WebKit draws in another process; cacheDisplay alone omits its rendered content.
@MainActor
func compositeMarkdownSnapshots(in root: NSView, onto bitmap: NSBitmapImageRep) {
    func collect(_ view: NSView) -> [WKWebView] {
        guard !view.isHiddenOrHasHiddenAncestor else { return [] }
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap { collect($0) }
    }
    for web in collect(root) {
        var snapshot: NSImage?
        var finished = false
        web.takeSnapshot(with: nil) { image, _ in snapshot = image; finished = true }
        let deadline = Date().addingTimeInterval(3)
        while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard let snapshot, let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
        var rect = web.convert(web.bounds, to: root)
        if root.isFlipped { rect.origin.y = root.bounds.height - rect.maxY }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(bitmap.pixelsWide) / root.bounds.width, y: CGFloat(bitmap.pixelsHigh) / root.bounds.height)
        context.cgContext.setFillColor(NSColor.white.cgColor); context.cgContext.fill(rect)
        snapshot.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }
}
