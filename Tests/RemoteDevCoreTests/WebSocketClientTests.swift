import Testing
import Foundation
@testable import RemoteDevCore

@Suite("WebSocketClient")
struct WebSocketClientTests {

    @Test("Session config disables both timeouts to prevent silent WebSocket disconnects")
    func testSessionConfigDisablesTimeouts() {
        let config = WebSocketClient.makeSessionConfiguration()

        // Default timeoutIntervalForRequest is 60s — if left at default,
        // URLSession silently closes WebSocket connections after ~60-90s.
        // This caused a production bug where connections dropped with no error.
        #expect(config.timeoutIntervalForRequest == 0,
                "timeoutIntervalForRequest must be 0 (was \(config.timeoutIntervalForRequest))")
        #expect(config.timeoutIntervalForResource == 0,
                "timeoutIntervalForResource must be 0 (was \(config.timeoutIntervalForResource))")
        #expect(config.shouldUseExtendedBackgroundIdleMode == true,
                "shouldUseExtendedBackgroundIdleMode must be true")
    }
}
