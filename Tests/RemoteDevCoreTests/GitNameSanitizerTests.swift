import Testing
@testable import RemoteDevCore

@Suite("GitNameSanitizer")
struct GitNameSanitizerTests {

    @Test("Spaces replaced with hyphens")
    func spaces() {
        #expect(GitNameSanitizer.sanitize("my feature") == "my-feature")
    }

    @Test("Illegal git chars replaced")
    func illegalChars() {
        #expect(GitNameSanitizer.sanitize("a^b:c?d") == "a-b-c-d")
    }

    @Test("Double dots collapsed")
    func doubleDots() {
        #expect(GitNameSanitizer.sanitize("a..b") == "a.b")
    }

    @Test("Leading and trailing dots stripped")
    func leadingTrailingDots() {
        #expect(GitNameSanitizer.sanitize(".hidden.") == "hidden")
    }

    @Test("Whitespace-only becomes empty")
    func whitespaceOnly() {
        #expect(GitNameSanitizer.sanitize("  ") == "")
    }

    @Test("All-illegal becomes empty")
    func allIllegal() {
        #expect(GitNameSanitizer.sanitize("***") == "")
    }

    @Test("Valid name passes through")
    func validPassthrough() {
        #expect(GitNameSanitizer.sanitize("valid-name") == "valid-name")
    }

    @Test("Consecutive spaces collapsed into single hyphen")
    func consecutiveSpaces() {
        #expect(GitNameSanitizer.sanitize("hello   world") == "hello-world")
    }

    @Test("CJK characters pass through")
    func cjkPassthrough() {
        #expect(GitNameSanitizer.sanitize("功能測試") == "功能測試")
    }

    @Test("Trailing .lock stripped")
    func trailingLock() {
        #expect(GitNameSanitizer.sanitize("branch.lock") == "branch")
    }

    @Test("At-brace replaced")
    func atBrace() {
        #expect(GitNameSanitizer.sanitize("a@{b") == "a@b")
    }

    @Test("Slash replaced (folder safety)")
    func slashReplaced() {
        #expect(GitNameSanitizer.sanitize("feature/branch") == "feature-branch")
    }
}
