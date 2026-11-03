import AppKit
import SwiftUI

/// Keep both hosts alive while the window animates between a square card and the full workspace.
struct TaskSplitView<Sidebar: View, Detail: View>: NSViewRepresentable {
    let sidebar: Sidebar
    let detail: Detail
    let initialWidth: CGFloat
    let isCompact: Bool
    let isTransitioning: Bool
    let onWidthChanged: (CGFloat) -> Void
    func makeNSView(context: Context) -> TaskSplitHost<Sidebar, Detail> {
        TaskSplitHost(sidebar: sidebar, detail: detail, initialWidth: initialWidth, onWidthChanged: onWidthChanged)
    }
    func updateNSView(_ view: TaskSplitHost<Sidebar, Detail>, context: Context) {
        view.sidebar.rootView = sidebar
        view.detail.rootView = detail
        view.configure(compact: isCompact, transitioning: isTransitioning, width: initialWidth)
    }
}

final class TaskSplitHost<Sidebar: View, Detail: View>: NSSplitView, NSSplitViewDelegate {
    let sidebar: NSHostingView<Sidebar>
    let detail: NSHostingView<Detail>
    private let detailClip = NSView()
    private var sidebarWidth: CGFloat
    private var compact = false
    private var transitioning = false
    private let onWidthChanged: (CGFloat) -> Void
    private var arrangingFrames = false
    override var dividerThickness: CGFloat { compact && !transitioning ? 0 : 1 }
    init(sidebar: Sidebar, detail: Detail, initialWidth: CGFloat, onWidthChanged: @escaping (CGFloat) -> Void) {
        self.sidebarWidth = initialWidth
        self.onWidthChanged = onWidthChanged
        self.sidebar = NSHostingView(rootView: sidebar)
        self.detail = NSHostingView(rootView: detail)
        super.init(frame: NSRect(x: 0, y: 0, width: 940, height: 600))
        wantsLayer = true; layer?.masksToBounds = true
        isVertical = true; dividerStyle = .thin; delegate = self
        detailClip.wantsLayer = true; detailClip.layer?.masksToBounds = true
        detailClip.addSubview(self.detail)
        addSubview(self.sidebar); addSubview(detailClip)
        resizeSubviews(withOldSize: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(compact: Bool, transitioning: Bool, width: CGFloat) {
        self.compact = compact; self.transitioning = transitioning; self.sidebarWidth = width
        detailClip.isHidden = compact && !transitioning
        resizeSubviews(withOldSize: bounds.size)
        needsDisplay = true
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        arrangingFrames = true
        defer { arrangingFrames = false }
        let width: CGFloat
        if compact && !transitioning {
            width = bounds.width
            if width >= 180 && width <= 440 {
                sidebarWidth = width; onWidthChanged(width)
            }
        } else if transitioning {
            width = min(sidebarWidth, max(0, bounds.width - dividerThickness))
        } else {
            width = max(0, min(sidebarWidth, min(440, bounds.width - dividerThickness - 340)))
        }
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        detailClip.frame = NSRect(x: width + dividerThickness, y: 0,
                                  width: max(0, bounds.width - width - dividerThickness), height: bounds.height)
        detail.frame = NSRect(x: 0, y: 0, width: max(340, detailClip.bounds.width), height: bounds.height)
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { compact || transitioning ? sidebar.frame.width : 180 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        compact || transitioning ? sidebar.frame.width : min(440, bounds.width - dividerThickness - 340)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !arrangingFrames, !compact, !transitioning, sidebar.frame.width >= 180 else { return }
        sidebarWidth = sidebar.frame.width; onWidthChanged(sidebarWidth)
    }
}
