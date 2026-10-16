import Foundation
import Testing
@testable import ChiikawaPet

struct ClaudeCredentialTests {
    @Test func acceptsToolOutputWithTrailingNewline() throws {
        let output = Data((#"{"claudeAiOauth":{"accessToken":"current-account"}}"# + "\n").utf8)
        #expect(try UsageClient.claudeToken(fromSecurityOutput: output) == "current-account")
    }

    @Test func decodesSecurityHexOutputForMultilineJSON() throws {
        let json = "{\n  \"claudeAiOauth\": {\"accessToken\": \"switched-account\"}\n}"
        let hexadecimal = json.utf8.map { String(format: "%02x", $0) }.joined() + "\n"
        #expect(try UsageClient.claudeToken(fromSecurityOutput: Data(hexadecimal.utf8)) == "switched-account")
    }

    @Test(arguments: ["", "\n", "not-json", "abc", "gg", "{}", #"{"claudeAiOauth":{"accessToken":""}}"#, #"{"claudeAiOauth":{"accessToken":"bad\r\nheader"}}"#, #"{"claudeAiOauth":{"accessToken":"with space"}}"#])
    func rejectsEmptyMalformedOrUnsafeOutput(output: String) throws {
        #expect(try UsageClient.claudeToken(fromSecurityOutput: Data(output.utf8)) == nil)
    }

    @Test func rejectsExpiredAndMalformedCredentialJSON() {
        let expired = Data(#"{"claudeAiOauth":{"accessToken":"expired-token","expiresAt":1}}"#.utf8)
        #expect(throws: UsageFailure.self) {
            try UsageClient.claudeToken(fromSecurityOutput: expired)
        }
        let malformed = Data("{broken-json".utf8)
        #expect(throws: UsageFailure.self) {
            try UsageClient.claudeToken(fromSecurityOutput: malformed)
        }
    }
}
