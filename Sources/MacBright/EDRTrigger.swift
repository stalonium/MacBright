import AppKit
import Metal
import QuartzCore

/// A 1×1 pt borderless window that draws a single black pixel into an
/// EDR-enabled Metal layer.
///
/// Just having this layer on screen makes macOS switch the display into EDR
/// (HDR) mode: the backlight is driven harder and regular SDR content is scaled
/// down to compensate, which leaves "headroom" above SDR white. The pixel is
/// black, so it stays invisible — and stays black after the gamma boost too.
@MainActor
final class EDRTrigger {
    private let window: NSWindow
    private let view: EDRPixelView

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }

        view = EDRPixelView(device: device, queue: queue)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.canHide = false
        window.sharingType = .none
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = view
    }

    /// Shows the trigger in the bottom-left corner of `screen`. Cheap to call
    /// repeatedly; it only redraws when something actually changed.
    func show(on screen: NSScreen) {
        let frame = NSRect(origin: screen.frame.origin, size: NSSize(width: 1, height: 1))
        guard !window.isVisible || window.frame != frame else { return }
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        view.render()
    }

    /// Hides and re-shows the trigger, for when macOS seems to have lost track of it.
    func refresh(on screen: NSScreen) {
        window.orderOut(nil)
        show(on: screen)
    }

    func hide() {
        window.orderOut(nil)
    }
}

private final class EDRPixelView: NSView {
    private let metalLayer = CAMetalLayer()
    private let queue: MTLCommandQueue

    init(device: MTLDevice, queue: MTLCommandQueue) {
        self.queue = queue
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        metalLayer.device = device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.framebufferOnly = true
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer { metalLayer }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render()
    }

    func render() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        guard let drawable = metalLayer.nextDrawable(),
              let commands = queue.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        commands.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
