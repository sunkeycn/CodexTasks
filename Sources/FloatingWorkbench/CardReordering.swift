import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LiteCore

/// A nonce identifies this app's current drag; unrelated text drops never reorder cards.
private final class CardDragContext: ObservableObject {
    static let shared = CardDragContext()
    var scope = ""
    var id = ""
    @Published var payload = ""
}

struct CardClickTarget {
    let bounds: Anchor<CGRect>
    let action: () -> Void
}

struct CardClickTargetsKey: PreferenceKey {
    static let defaultValue: [CardClickTarget] = []
    static func reduce(value: inout [CardClickTarget], nextValue: () -> [CardClickTarget]) { value += nextValue() }
}

struct CardReordering: ViewModifier {
    let id: String
    let scope: String
    let onClick: () -> Void
    let move: (String, SortPlacement) -> Void
    @ObservedObject private var dragContext = CardDragContext.shared
    @State private var placement: SortPlacement?
    @State private var height: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(CardClickTargetsKey.self) { targets in
                GeometryReader { geometry in
                    CardDragSurface(id: id, scope: scope) { point in
                        if let target = targets.first(where: { geometry[$0.bounds].contains(point) }) { target.action() }
                        else { onClick() }
                    }
                }
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { height = geometry.size.height }
                        .onChange(of: geometry.size.height) { height = $0 }
                }
            }
            .onDrop(of: [.utf8PlainText], delegate: CardDropDelegate(
                id: id, scope: scope, height: height, placement: $placement, move: move))
            .onChange(of: dragContext.payload) { _ in placement = nil }
            .overlay(alignment: placement == .after ? .bottom : .top) {
                if !dragContext.payload.isEmpty && placement != nil {
                    Capsule().fill(Color.accentColor).frame(height: 3).allowsHitTesting(false)
                }
            }
    }
}

private struct CardDropDelegate: DropDelegate {
    let id: String
    let scope: String
    let height: CGFloat
    @Binding var placement: SortPlacement?
    let move: (String, SortPlacement) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        let drag = CardDragContext.shared
        return !drag.payload.isEmpty && drag.scope == scope && info.hasItemsConforming(to: [.utf8PlainText])
    }
    func dropEntered(info: DropInfo) {
        placement = CardDragContext.shared.id == id ? nil : (info.location.y < height / 2 ? .before : .after)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        placement = CardDragContext.shared.id == id ? nil : (info.location.y < height / 2 ? .before : .after)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { placement = nil }
    func performDrop(info: DropInfo) -> Bool {
        let position: SortPlacement = info.location.y < height / 2 ? .before : .after
        placement = nil
        guard validateDrop(info: info), let provider = info.itemProviders(for: [.utf8PlainText]).first else { return false }
        let source = CardDragContext.shared.id
        let payload = CardDragContext.shared.payload
        CardDragContext.shared.payload = ""
        guard source != id else { return true }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let value = object as? String, value == payload else { return }
            DispatchQueue.main.async { move(source, position) }
        }
        return true
    }
}


/// One native source covers the card. Clicks are dispatched only when the mouse was not dragged.
private struct CardDragSurface: NSViewRepresentable {
    let id: String
    let scope: String
    let onClick: (CGPoint) -> Void
    func makeNSView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: SurfaceView, context: Context) {
        view.id = id; view.scope = scope; view.onClick = onClick
    }

    final class SurfaceView: NSView, NSDraggingSource {
        var id = ""
        var scope = ""
        var onClick: ((CGPoint) -> Void)?
        private var mouseDownPoint: CGPoint?
        private var dragging = false
        override var isFlipped: Bool { true }
        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = convert(event.locationInWindow, from: nil)
            dragging = false
        }
        override func mouseUp(with event: NSEvent) {
            defer { mouseDownPoint = nil }
            guard mouseDownPoint != nil, !dragging else { return }
            let point = convert(event.locationInWindow, from: nil)
            if bounds.contains(point) { onClick?(point) }
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownPoint, !dragging else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
            dragging = true
            let drag = CardDragContext.shared
            drag.scope = scope; drag.id = id; drag.payload = "codex-tasks-order:\(UUID().uuidString)"
            let item = NSDraggingItem(pasteboardWriter: drag.payload as NSString)
            var preview: NSImage? = NSImage(systemSymbolName: "rectangle", accessibilityDescription: nil)
            if let host = window?.contentView {
                let rect = convert(bounds, to: host)
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: rect) {
                    host.cacheDisplay(in: rect, to: bitmap)
                    let image = NSImage(size: bounds.size); image.addRepresentation(bitmap); preview = image
                }
            }
            item.setDraggingFrame(bounds, contents: preview)
            beginDraggingSession(with: [item], event: event, source: self)
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            mouseDownPoint = nil; dragging = false; CardDragContext.shared.payload = ""
        }
    }
}
