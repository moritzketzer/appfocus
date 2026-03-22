// Tests/Unit/CommandProtocolTests.swift
import Testing

@Suite("Command Protocol")
struct CommandProtocolTests {

    // MARK: - Parsing

    @Test func parseNext() {
        let cmd = Command.parse("next\n")
        switch cmd {
        case .next: break
        default: Issue.record("Expected .next, got \(String(describing: cmd))")
        }
    }

    @Test func parsePrev() {
        let cmd = Command.parse("prev\n")
        switch cmd {
        case .prev: break
        default: Issue.record("Expected .prev, got \(String(describing: cmd))")
        }
    }

    @Test func parseStatus() {
        let cmd = Command.parse("status\n")
        switch cmd {
        case .status: break
        default: Issue.record("Expected .status, got \(String(describing: cmd))")
        }
    }

    @Test func parseJump() {
        let cmd = Command.parse("jump Safari\n")
        switch cmd {
        case .jump(let name): #expect(name == "Safari")
        default: Issue.record("Expected .jump, got \(String(describing: cmd))")
        }
    }

    @Test func parseJumpMultiWord() {
        let cmd = Command.parse("jump Visual Studio Code\n")
        switch cmd {
        case .jump(let name): #expect(name == "Visual Studio Code")
        default: Issue.record("Expected .jump, got \(String(describing: cmd))")
        }
    }

    @Test func parseJumpEmptyName() {
        let cmd = Command.parse("jump \n")
        #expect(cmd == nil)
    }

    @Test func parseUnknown() {
        #expect(Command.parse("foo\n") == nil)
    }

    @Test func parseEmpty() {
        #expect(Command.parse("") == nil)
    }

    @Test func parseTrimsWhitespace() {
        let cmd = Command.parse("  next  \n")
        switch cmd {
        case .next: break
        default: Issue.record("Expected .next, got \(String(describing: cmd))")
        }
    }

    // MARK: - Serialization

    @Test func serializeNext() {
        #expect(Command.next.serialize() == "next\n")
    }

    @Test func serializePrev() {
        #expect(Command.prev.serialize() == "prev\n")
    }

    @Test func serializeStatus() {
        #expect(Command.status.serialize() == "status\n")
    }

    @Test func serializeJump() {
        #expect(Command.jump(appName: "Safari").serialize() == "jump Safari\n")
    }

    // MARK: - Roundtrip

    @Test func roundtripNext() {
        let cmd = Command.next
        let parsed = Command.parse(cmd.serialize())
        switch parsed {
        case .next: break
        default: Issue.record("Roundtrip failed")
        }
    }

    @Test func roundtripJump() {
        let cmd = Command.jump(appName: "Visual Studio Code")
        let parsed = Command.parse(cmd.serialize())
        switch parsed {
        case .jump(let name): #expect(name == "Visual Studio Code")
        default: Issue.record("Roundtrip failed")
        }
    }
}
