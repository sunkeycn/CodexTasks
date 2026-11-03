import AppKit
import SwiftUI

/// Own the split frames natively so SwiftUI content updates cannot reset a dragged divider.
struct TaskSplitView<Sidebar: View, Detail: View>: NSViewRepresentable {
    let sidebar: Sidebar
    let detail: Detail
    let initialWidth: CGFloat
    let onWidthChanged: (CGFloat) -> Void
    func makeNSView(context: Context) -> TaskSplitHost<Sidebar, Detail> {
        TaskSplitHost(sidebar: sidebar, detail: detail, initialWidth: initialWidth, onWidthChanged: onWidthChanged)
    }
    func updateNSView(_ view: TaskSplitHost<Sidebar, Detail>, context: Context) {
        view.sidebar.rootView = sidebar
        view.detail.rootView = detail
    }
}

final class TaskSplitHost<Sidebar: View, Detail: View>: NSSplitView, NSSplitViewDelegate {
    let sidebar: NSHostingView<Sidebar>
    let detail: NSHostingView<Detail>
    private var sidebarWidth: CGFloat
    private let onWidthChanged: (CGFloat) -> Void
    private var arrangingFrames = false
    init(sidebar: Sidebar, detail: Detail, initialWidth: CGFloat, onWidthChanged: @escaping (CGFloat) -> Void) {
        self.sidebarWidth = initialWidth
        self.onWidthChanged = onWidthChanged
        self.sidebar = NSHostingView(rootView: sidebar)
        self.detail = NSHostingView(rootView: detail)
        super.init(frame: NSRect(x: 0, y: 0, width: 940, height: 600))
        isVertical = true
        dividerStyle = .thin
        delegate = self
        addSubview(self.sidebar)
        addSubview(self.detail)
        resizeSubviews(withOldSize: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        arrangingFrames = true
        defer { arrangingFrames = false }
        let width = max(0, min(sidebarWidth, min(440, bounds.width - dividerThickness - 340)))
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        detail.frame = NSRect(x: width + dividerThickness, y: 0,
                              width: max(0, bounds.width - width - dividerThickness), height: bounds.height)
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 180 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(440, bounds.width - dividerThickness - 340)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !arrangingFrames, sidebar.frame.width >= 180 else { return }
        sidebarWidth = sidebar.frame.width
        onWidthChanged(sidebarWidth)
    }
}
