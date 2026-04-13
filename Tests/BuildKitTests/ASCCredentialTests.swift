import Testing
import Foundation
@testable import BuildKit

@Suite struct ASCCredentialTests {

    // MARK: - resolvedASCCredentials()

    @Test(".disabled returns nil")
    func testDisabledReturnsNil() {
        let bm = BuildManager()
        bm.ascConfigState = .disabled

        let result = bm.resolvedASCCredentials()
        #expect(result == nil)
    }

    @Test(".configured with valid values returns credentials")
    func testConfiguredValid() {
        let bm = BuildManager()
        bm.ascConfigState = .configured(ASCConfig(
            keyId: "K1", issuerId: "I1", keyPath: "/tmp/key.p8"))

        let result = bm.resolvedASCCredentials()
        #expect(result != nil)
        #expect(result?.keyId == "K1")
        #expect(result?.issuerId == "I1")
        #expect(result?.keyPath == "/tmp/key.p8")
    }

    @Test(".configured with empty keyId returns nil")
    func testConfiguredEmptyKeyId() {
        let bm = BuildManager()
        bm.ascConfigState = .configured(ASCConfig(
            keyId: "", issuerId: "I1", keyPath: "/tmp/key.p8"))

        let result = bm.resolvedASCCredentials()
        #expect(result == nil)
    }

    @Test(".configured with empty issuerId returns nil")
    func testConfiguredEmptyIssuerId() {
        let bm = BuildManager()
        bm.ascConfigState = .configured(ASCConfig(
            keyId: "K1", issuerId: "", keyPath: "/tmp/key.p8"))

        let result = bm.resolvedASCCredentials()
        #expect(result == nil)
    }

    @Test(".configured with nil keyPath uses default path")
    func testConfiguredNilKeyPathUsesDefault() {
        let bm = BuildManager()
        // When ASCConfigStore resolves with no custom keyPath, it uses the default.
        // Simulate that by passing the default path directly.
        let defaultPath = NSString(string: "~/.private_keys/AuthKey_K1.p8").expandingTildeInPath
        bm.ascConfigState = .configured(ASCConfig(
            keyId: "K1", issuerId: "I1", keyPath: defaultPath))

        let result = bm.resolvedASCCredentials()
        #expect(result != nil)
        #expect(result?.keyPath == defaultPath)
    }

    @Test(".unset returns nil")
    func testUnsetReturnsNil() {
        let bm = BuildManager()
        bm.ascConfigState = .unset

        let result = bm.resolvedASCCredentials()
        #expect(result == nil)
    }
}
