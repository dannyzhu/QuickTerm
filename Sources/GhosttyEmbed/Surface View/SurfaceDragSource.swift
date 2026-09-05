import AppKit
import Combine
import SwiftUI

extension Ghostty {
    /// A preference key that propagates the ID of the SurfaceView currently being dragged,
    /// or nil if no surface is being dragged.
    struct DraggingSurfaceKey: PreferenceKey {
        static var defaultValue: PaneView.ID?

        static func reduce(value: inout PaneView.ID?, nextValue: () -> PaneView.ID?) {
            value = nextValue() ?? value
        }
    }

    /// A SwiftUI view that provides drag source functionality for terminal surfaces.
    ///
    /// This view wraps an AppKit-based drag source to enable drag-and-drop reordering
    /// of terminal surfaces within split views. When the user drags this view, it initiates
    /// an `NSDraggingSession` with the surface's UUID encoded in the pasteboard, allowing
    /// drop targets to identify which surface is being moved.
    ///
    /// The view also publishes the dragging state via `DraggingSurfaceKey` preference,
    /// enabling parent views to react to ongoing drag operations.
    struct SurfaceDragSource: View {
        /// The surface view that will be dragged.
        let surfaceView: PaneView

        /// Binding that reflects whether a drag session is currently active.
        @Binding var isDragging: Bool

        /// Binding that reflects whether the mouse is hovering over this view.
        @Binding var isHovering: Bool

        var body: some View {
            SurfaceDragSourceViewRepresentable(
                surfaceView: surfaceView,
                isDragging: $isDragging,
                isHovering: $isHovering)
            .preference(key: DraggingSurfaceKey.self, value: isDragging ? surfaceView.id : nil)
        }
    }

    /// An NSViewRepresentable that provides AppKit-based drag source functionality.
    /// This gives us control over the drag lifecycle, particularly detecting drag start.
    fileprivate struct SurfaceDragSourceViewRepresentable: NSViewRepresentable {
        let surfaceView: PaneView
        @Binding var isDragging: Bool
        @Binding var isHovering: Bool

        func makeNSView(context: Context) -> SurfaceDragSourceView {
            let view = SurfaceDragSourceView()
            view.surfaceView = surfaceView
            view.onDragStateChanged = { dragging in
                isDragging = dragging
            }
            view.onHoverChanged = { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
            return view
        }

        func updateNSView(_ nsView: SurfaceDragSourceView, context: Context) {
            nsView.surfaceView = surfaceView
            nsView.onDragStateChanged = { dragging in
                isDragging = dragging
            }
            nsView.onHoverChanged = { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
        }
    }

    /// The underlying NSView that handles drag operations.
    ///
    /// This view manages mouse tracking and drag initiation for surface reordering.
    /// It uses a local event loop to detect drag gestures and initiates an
    /// `NSDraggingSession` when the user drags beyond the threshold distance.
    fileprivate class SurfaceDragSourceView: NSView, NSDraggingSource {
        /// Scale factor applied to the surface snapshot for the drag preview image.
        private static let previewScale: CGFloat = 0.2

        /// The surface view that will be dragged. Its UUID is encoded into the
        /// pasteboard for drop targets to identify which surface is being moved.
        var surfaceView: PaneView? {
            didSet {
                // QuickTerm：终端报告"指着链接"（pointerStyle = .link）时重算光标矩形，⌘ 下也能看到链接指针
                pointerObserver = (surfaceView as? Ghostty.SurfaceView)?.$pointerStyle
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in
                        guard let self, let window = self.window else { return }
                        window.invalidateCursorRects(for: self)
                    }
            }
        }
        private var pointerObserver: AnyCancellable?

        /// Callback invoked when the drag state changes. Called with `true` when
        /// a drag session begins, and `false` when it ends (completed or cancelled).
        var onDragStateChanged: ((Bool) -> Void)?

        /// Callback invoked when the mouse enters or exits this view's bounds.
        /// Used to update the hover state for visual feedback in the parent view.
        var onHoverChanged: ((Bool) -> Void)?

        /// Whether we are currently in a mouse tracking loop (between mouseDown
        /// and either mouseUp or drag initiation). Used to determine cursor state.
        private var isTracking: Bool = false

        /// Local event monitor to detect escape key presses during drag.
        private var escapeMonitor: Any?

        /// Whether the current drag was cancelled by pressing escape.
        private var dragCancelledByEscape: Bool = false

        /// QuickTerm：按下但还没拖过阈值的那次 mouseDown。纯点击（抬起时仍在）整体转交给 pane 本体——
        /// ⌘+点击链接靠引擎在 release 时 open_url，浮层吞掉按下/抬起就永远开不了；
        /// 不能在按下时就转发：随后开始拖拽的话 surface 永远收不到 release，引擎会以为左键一直按着
        private var pendingClick: NSEvent?
        /// 拖过这个距离才开始 DnD（之前一动就拖，点击时手抖一下就变成拖 pane）
        private static let dragThreshold: CGFloat = 4

        deinit {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
            }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            // Ensure this view gets the mouse event before window dragging handlers
            return true
        }

        override func mouseDown(with event: NSEvent) {
            // Consume the mouseDown event to prevent it from propagating to the
            // window's drag handler. This fixes issue #10110 where grab handles
            // would drag the window instead of initiating pane drags.
            // Don't call super - the drag will be initiated in mouseDragged.
            pendingClick = event   // QuickTerm：记下，抬起时若没拖就当点击转交
        }

        /// QuickTerm：没拖过阈值就抬起 = 纯点击，按下 + 抬起一并交给 pane 的键盘焦点视图
        /// （终端 = SurfaceView → 引擎 PRESS/RELEASE；浏览器 = WKWebView）
        override func mouseUp(with event: NSEvent) {
            guard let down = pendingClick else { return }
            pendingClick = nil
            guard let target = surfaceView?.clickTarget(atWindowPoint: down.locationInWindow) else { return }
            target.mouseDown(with: down)
            target.mouseUp(with: event)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            // To update our tracking area we just recreate it all.
            trackingAreas.forEach { removeTrackingArea($0) }

            // Add our tracking area for mouse events
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp],
                owner: self,
                userInfo: nil
            ))
        }

        override func resetCursorRects() {
            // QuickTerm：⌘ 悬停在链接上显示链接指针而不是抓手（⌘+点击链接是正式功能，得有提示）。
            // 光标仲裁走命中视图（本浮层）自己的矩形，不能只是"不加矩形"——那样会沿本浮层的响应链往上走，
            // 永远到不了终端滚动视图的 documentCursor
            if !isTracking, let terminal = surfaceView as? Ghostty.SurfaceView, terminal.pointerStyle == .link {
                addCursorRect(bounds, cursor: .pointingHand)
                return
            }
            addCursorRect(bounds, cursor: isTracking ? .closedHand : .openHand)
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChanged?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChanged?(false)
        }

        override func mouseDragged(with event: NSEvent) {
            guard !isTracking, let surfaceView = surfaceView else { return }
            // QuickTerm：过了阈值才算拖拽
            if let down = pendingClick {
                let dx = event.locationInWindow.x - down.locationInWindow.x
                let dy = event.locationInWindow.y - down.locationInWindow.y
                if hypot(dx, dy) < Self.dragThreshold { return }
                pendingClick = nil
            }

            // Create our dragging item from our transferable
            guard let pasteboardItem = surfaceView.pasteboardItem() else { return }
            let item = NSDraggingItem(pasteboardWriter: pasteboardItem)

            // Create a scaled preview image from the surface snapshot
            if let snapshot = surfaceView.asImage {
                let imageSize = NSSize(
                    width: snapshot.size.width * Self.previewScale,
                    height: snapshot.size.height * Self.previewScale
                )
                let scaledImage = NSImage(size: imageSize)
                scaledImage.lockFocus()
                snapshot.draw(
                    in: NSRect(origin: .zero, size: imageSize),
                    from: NSRect(origin: .zero, size: snapshot.size),
                    operation: .copy,
                    fraction: 1.0
                )
                scaledImage.unlockFocus()

                // Position the drag image so the mouse is at the center of the image.
                // I personally like the top middle or top left corner best but
                // this matches macOS native tab dragging behavior (at least, as of
                // macOS 26.2 on Dec 29, 2025).
                let mouseLocation = convert(event.locationInWindow, from: nil)
                let origin = NSPoint(
                    x: mouseLocation.x - imageSize.width / 2,
                    y: mouseLocation.y - imageSize.height / 2
                )
                item.setDraggingFrame(
                    NSRect(origin: origin, size: imageSize),
                    contents: scaledImage
                )
            }

            onDragStateChanged?(true)
            let session = beginDraggingSession(with: [item], event: event, source: self)

            // We need to disable this so that endedAt happens immediately for our
            // drags outside of any targets.
            session.animatesToStartingPositionsOnCancelOrFail = false
        }

        // MARK: NSDraggingSource

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            return context == .withinApplication ? .move : []
        }

        func draggingSession(
            _ session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint
        ) {
            isTracking = true

            // Reset our escape tracking
            dragCancelledByEscape = false
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { // Escape key
                    self?.dragCancelledByEscape = true
                }
                return event
            }
        }

        func draggingSession(
            _ session: NSDraggingSession,
            movedTo screenPoint: NSPoint
        ) {
            NSCursor.closedHand.set()
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
                self.escapeMonitor = nil
            }

            if operation == [] && !dragCancelledByEscape {
                let endsInWindow = NSApplication.shared.windows.contains { window in
                    window.isVisible && window.frame.contains(screenPoint)
                }
                if !endsInWindow {
                    NotificationCenter.default.post(
                        name: .ghosttySurfaceDragEndedNoTarget,
                        object: surfaceView,
                        userInfo: [Foundation.Notification.Name.ghosttySurfaceDragEndedNoTargetPointKey: screenPoint]
                    )
                }
            }

            isTracking = false
            onDragStateChanged?(false)
        }
    }
}

extension Notification.Name {
    /// Posted when a surface drag session ends with no operation (the drag was
    /// released outside a valid drop target) and was not cancelled by the user
    /// pressing escape. The notification's object is the SurfaceView that was dragged.
    static let ghosttySurfaceDragEndedNoTarget = Notification.Name("ghosttySurfaceDragEndedNoTarget")

    /// Key for the screen point where the drag ended in the userInfo dictionary.
    static let ghosttySurfaceDragEndedNoTargetPointKey = "endedAtPoint"
}
