import Foundation
import CoreImage
import AppKit
import RemoteDevCore

#if os(macOS)
struct QRRenderer {

    // MARK: - Strategy

    enum DisplayResult {
        case gui(QRWindowController)
        case consoleOnly
    }

    /// Show QR code via GUI window (default) or terminal ASCII (`consoleOnly`).
    /// Returns a `DisplayResult` so the caller can dismiss the GUI window later.
    ///
    /// `expiration` is the single source of truth for the token TTL — the same
    /// value the caller wrote into the `PairingTokenFile` on disk. Any drift
    /// between QR payload and on-disk file is a cross-layer bug.
    @discardableResult
    static func showQR(relayURL: String, roomID: String, pairingToken: String,
                        macPubkey: String, expiration: Int,
                        roomName: String? = nil,
                        consoleOnly: Bool = false) -> DisplayResult {
        let payload = buildPayload(relayURL: relayURL, roomID: roomID,
                                    pairingToken: pairingToken, macPubkey: macPubkey,
                                    expiration: expiration, roomName: roomName)

        if consoleOnly {
            printQR(payload: payload)
            return .consoleOnly
        }

        // GUI mode: show floating window if environment supports it
        if canShowGUI(), let cgImage = generateCGImage(payload: payload, scale: 10) {
            let controller = QRWindowController()
            controller.show(cgImage: cgImage)
            return .gui(controller)
        }

        // GUI not available — fall back to terminal rendering
        printQR(payload: payload)
        return .consoleOnly
    }

    /// Detect whether we can display a GUI window.
    /// Returns false for non-interactive processes (launchd), SSH, or headless servers.
    /// Set FORCE_QR_WINDOW=1 to bypass checks (used by automated testing).
    static func canShowGUI() -> Bool {
        if ProcessInfo.processInfo.environment["FORCE_QR_WINDOW"] == "1" {
            return true
        }
        // Non-interactive (launchd daemon) — don't pop up windows
        if isatty(STDIN_FILENO) == 0 {
            return false
        }
        // SSH sessions can't display GUI windows on the local display
        if ProcessInfo.processInfo.environment["SSH_TTY"] != nil {
            return false
        }
        // Check for an active GUI login session (fails on headless servers)
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
           let onConsole = dict["kCGSSessionOnConsoleKey"] as? Bool {
            return onConsole
        }
        return false
    }

    // MARK: - Payload

    /// Build v2 compact JSON payload with pairing token (no room secret).
    /// Keys: v (version), r (relay URL), i (room ID), k (mac pubkey),
    ///       p (pairing token), e (expiration), n (room name, optional).
    static func buildPayload(relayURL: String, roomID: String, pairingToken: String,
                              macPubkey: String, expiration: Int,
                              roomName: String? = nil) -> String {
        var dict: [(String, Any)] = [
            ("v", 2),
            ("r", relayURL),
            ("i", roomID),
            ("k", macPubkey),
            ("p", pairingToken),
            ("e", expiration),
        ]
        if let roomName {
            dict.append(("n", roomName))
        }
        return buildCompactJSON(dict)
    }

    private static func buildCompactJSON(_ dict: [(String, Any)]) -> String {
        let fields = dict.map { key, value in
            if let s = value as? String {
                return "\"\(key)\":\"\(escapeJSON(s))\""
            } else {
                return "\"\(key)\":\(value)"
            }
        }
        return "{\(fields.joined(separator: ","))}"
    }

    // MARK: - QR Generation + Rendering

    /// Generate a QR code from the payload and print it to the terminal
    /// using compact Unicode half-block characters.
    static func printQR(payload: String) {
        guard let matrix = generateModuleMatrix(payload: payload) else {
            log("[qr] Failed to generate QR code")
            return
        }
        let moduleWidth = matrix[0].count
        let cols = terminalWidth()
        let cw = blockCharWidth()  // 1 on Latin locales, 2 on CJK

        // Find largest border that fits: try 2, 1, 0
        // With half-blocks, each character = 1 module wide
        var effectiveBorder = 0
        for b in [2, 1, 0] {
            let charWidth = moduleWidth + 2 * b
            if charWidth * cw <= cols {
                effectiveBorder = b
                break
            }
        }

        // If even border=0 doesn't fit, show text fallback
        let minCharWidth = moduleWidth
        if minCharWidth * cw > cols {
            log("  [qr] Terminal too narrow (\(cols) cols) for QR code.")
            log("  [qr] Widen terminal or use 'termonmac pair' from a wider window.")
            return
        }

        print()
        print("  Scan this QR code with the TermOnMac iOS app:")
        print()
        renderCompactQR(matrix: matrix, border: effectiveBorder, invert: true)
        print()
    }

    // MARK: - CoreImage QR Generation

    /// Use CoreImage's CIQRCodeGenerator to produce a boolean module matrix.
    private static func generateModuleMatrix(payload: String) -> [[Bool]]? {
        guard let data = payload.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }

        // The CIImage is 1 pixel per module; read raw pixel data
        let extent = ciImage.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }

        // Use createCGImage + CGContext instead of CIContext.render(toBitmap:)
        // which is unreliable with .L8 / linearGray for QR generator output.
        let ciCtx = CIContext(options: nil)
        guard let cgImage = ciCtx.createCGImage(ciImage, from: extent) else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 255, count: width * height)
        guard let bitmapCtx = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        bitmapCtx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var matrix = [[Bool]]()
        for y in 0..<height {
            var row = [Bool]()
            for x in 0..<width {
                row.append(pixels[y * width + x] < 128)
            }
            matrix.append(row)
        }
        return matrix
    }

    // MARK: - CGImage

    /// Generate a scaled-up CGImage suitable for GUI display.
    /// Each QR module becomes `scale × scale` pixels, with a white quiet zone border.
    static func generateCGImage(payload: String, scale: Int = 10) -> CGImage? {
        guard let matrix = generateModuleMatrix(payload: payload) else { return nil }
        let border = 4  // quiet zone in modules
        let moduleCount = matrix.count
        let totalModules = moduleCount + border * 2
        let size = totalModules * scale

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil,
            width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // Fill white background
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

        // Draw dark modules
        ctx.setFillColor(gray: 0, alpha: 1)
        for y in 0..<moduleCount {
            for x in 0..<moduleCount where matrix[y][x] {
                let px = (x + border) * scale
                let py = (moduleCount - 1 - y + border) * scale  // flip Y for CGContext
                ctx.fill(CGRect(x: px, y: py, width: scale, height: scale))
            }
        }

        return ctx.makeImage()
    }

    // MARK: - Compact Unicode Rendering

    /// Render a module matrix using Unicode half-block characters.
    /// Each character encodes 1 column × 2 rows of modules, giving a 1:1 module
    /// aspect ratio since terminal cells are ~2:1 (height:width).
    /// When `invert` is true, dark/light are swapped (white background, dark modules)
    /// which produces a white-bordered QR that scans well on dark terminals.
    private static func renderCompactQR(matrix: [[Bool]], border: Int, invert: Bool) {
        let mc = matrix.count
        let total = mc + 2 * border
        let paddedH = total + (total % 2)  // pad to even for 2-row grouping
        let paddedW = (matrix.first.map { $0.count + 2 * border } ?? total)

        func module(_ r: Int, _ c: Int) -> Bool {
            let mr = r - border
            let mc_ = c - border
            if mr >= 0, mr < matrix.count, mc_ >= 0, mc_ < matrix[mr].count {
                let dark = matrix[mr][mc_]
                return invert ? !dark : dark
            }
            return invert  // border: light normally, dark when inverted
        }

        var lines = [String]()
        for row in stride(from: 0, to: paddedH, by: 2) {
            var chars = [Character]()
            for col in 0..<paddedW {
                let top = module(row, col)
                let bot = (row + 1 < paddedH) ? module(row + 1, col) : invert
                switch (top, bot) {
                case (true, true):   chars.append("█")
                case (true, false):  chars.append("▀")
                case (false, true):  chars.append("▄")
                case (false, false): chars.append(" ")
                }
            }
            lines.append(String(chars))
        }
        print(lines.joined(separator: "\n"))
    }

    // MARK: - Terminal Width

    private static func terminalWidth() -> Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 {
            return Int(ws.ws_col)
        }
        return 80
    }

    /// How many terminal columns a single block character occupies.
    /// CJK locales render "ambiguous width" Unicode (▀ █ etc.) as full-width (2 cols).
    private static func blockCharWidth() -> Int {
        // U+2588 FULL BLOCK — representative of all quadrant/block chars
        let w = Int(wcwidth(0x2588))
        return w > 0 ? w : 1
    }

    // MARK: - JSON Helpers

    private static func escapeJSON(_ s: String) -> String {
        var result = ""
        for ch in s {
            switch ch {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.append(ch)
            }
        }
        return result
    }
}
#endif
