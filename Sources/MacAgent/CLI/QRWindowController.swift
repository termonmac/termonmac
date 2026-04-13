import Foundation
import AppKit
import CoreImage

#if os(macOS)
/// Displays a floating NSWindow with the QR code image.
/// Auto-dismisses when `dismiss()` is called (e.g. after successful pairing).
/// All AppKit operations are dispatched to the main thread, so `show()` and
/// `dismiss()` are safe to call from any thread (e.g. relay callbacks).
final class QRWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var countdownTimer: Timer?

    /// Show a floating QR window centered on screen.
    /// Safe to call from any thread.
    func show(cgImage: CGImage, title: String = "Scan to Pair", subtitle: String = "Scan this QR code with the TermOnMac iOS app") {
        let work = { [weak self] in
            guard let self else { return }

            // Ensure NSApplication is initialized for CLI processes
            let app = NSApplication.shared
            if app.activationPolicy() == .prohibited {
                app.setActivationPolicy(.accessory)
            }

            let qrSize: CGFloat = 280
            let padding: CGFloat = 32
            let windowWidth = qrSize + padding * 2
            let windowHeight = qrSize + padding * 2 + 80  // extra space for text + countdown

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = title
            window.level = .floating
            window.center()
            window.isReleasedWhenClosed = false

            let contentView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))

            // QR image view
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: qrSize, height: qrSize))
            let imageView = NSImageView(frame: NSRect(x: padding, y: 80, width: qrSize, height: qrSize))
            imageView.image = nsImage
            imageView.imageScaling = .scaleProportionallyUpOrDown
            contentView.addSubview(imageView)

            // Subtitle label
            let label = NSTextField(labelWithString: subtitle)
            label.frame = NSRect(x: padding, y: 44, width: qrSize, height: 20)
            label.alignment = .center
            label.font = NSFont.systemFont(ofSize: 13)
            label.textColor = .secondaryLabelColor
            contentView.addSubview(label)

            // Countdown label
            let countdownLabel = NSTextField(labelWithString: "")
            countdownLabel.frame = NSRect(x: padding, y: 16, width: qrSize, height: 18)
            countdownLabel.alignment = .center
            countdownLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            countdownLabel.textColor = .tertiaryLabelColor
            contentView.addSubview(countdownLabel)

            window.contentView = contentView
            window.delegate = self
            window.makeKeyAndOrderFront(nil)
            self.window = window

            // Start 5-minute countdown (Timer on main RunLoop)
            let expiry = Date().addingTimeInterval(300)
            self.countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                let remaining = Int(expiry.timeIntervalSinceNow)
                if remaining <= 0 {
                    countdownLabel.stringValue = "QR code expired"
                    timer.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self?.dismiss()
                    }
                } else {
                    let min = remaining / 60
                    let sec = remaining % 60
                    countdownLabel.stringValue = "Expires in \(min):\(String(format: "%02d", sec))"
                }
            }
            self.countdownTimer?.fire()
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// Whether the window is currently visible.
    var isShowing: Bool { window != nil }

    /// Dismiss the QR window. Safe to call from any thread.
    func dismiss() {
        let work = { [weak self] in
            guard let self else { return }
            self.countdownTimer?.invalidate()
            self.countdownTimer = nil
            self.window?.close()
            self.window = nil
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        window = nil
    }
}
#endif
