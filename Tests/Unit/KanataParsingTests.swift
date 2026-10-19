// Tests/Unit/KanataParsingTests.swift
import Foundation
import Testing

@Suite("Kanata Message Parsing")
struct KanataParsingTests {

    @Test func parseMessagePushJump() {
        let json = #"{"MessagePush":{"message":"jump Safari"}}"#
        let cmd = KanataCommandSource.parseMessage(json)
        switch cmd {
        case .jump(let name): #expect(name == "Safari")
        default: Issue.record("Expected .jump, got \(String(describing: cmd))")
        }
    }

    @Test func parseMessagePushNext() {
        let json = #"{"MessagePush":{"message":"next"}}"#
        let cmd = KanataCommandSource.parseMessage(json)
        switch cmd {
        case .next: break
        default: Issue.record("Expected .next, got \(String(describing: cmd))")
        }
    }

    @Test func parseMessagePushPrev() {
        let json = #"{"MessagePush":{"message":"prev"}}"#
        let cmd = KanataCommandSource.parseMessage(json)
        switch cmd {
        case .prev: break
        default: Issue.record("Expected .prev, got \(String(describing: cmd))")
        }
    }

    @Test func ignoreLayerChange() {
        let json = #"{"LayerChange":{"new":"base"}}"#
        let cmd = KanataCommandSource.parseMessage(json)
        #expect(cmd == nil)
    }

    @Test func ignoreServerResponse() {
        let json = #"{"ServerResponse":"Ok"}"#
        let cmd = KanataCommandSource.parseMessage(json)
        #expect(cmd == nil)
    }

    @Test func malformedJson() {
        let cmd = KanataCommandSource.parseMessage("not json at all")
        #expect(cmd == nil)
    }

    @Test func emptyMessage() {
        let json = #"{"MessagePush":{"message":""}}"#
        let cmd = KanataCommandSource.parseMessage(json)
        #expect(cmd == nil)
    }

    @Test func messageWithExtraWhitespace() {
        let json = #"{"MessagePush":{"message":"  jump  Finder  "}}"#
        let cmd = KanataCommandSource.parseMessage(json)
        switch cmd {
        case .jump(let name): #expect(name == "Finder")
        default: Issue.record("Expected .jump, got \(String(describing: cmd))")
        }
    }

    // kanata sends message as a single-element array when push-msg argument
    // comes from concat/deftemplate expansion
    @Test func parseMessagePushArrayFormat() {
        let json = #"{"MessagePush":{"message":["jump Safari"]}}"#
        let cmd = KanataCommandSource.parseMessage(json)
        switch cmd {
        case .jump(let name): #expect(name == "Safari")
        default: Issue.record("Expected .jump, got \(String(describing: cmd))")
        }
    }

    @Test func parseMessagePushArrayNext() {
        let json = #"{"MessagePush":{"message":["next"]}}"#
        let cmd = KanataCommandSource.parseMessage(json)
        switch cmd {
        case .next: break
        default: Issue.record("Expected .next, got \(String(describing: cmd))")
        }
    }

    // One socket read can carry several envelopes and end mid-envelope. The
    // complete lines must come out whole and the tail must survive to be
    // finished by the next read — otherwise a burst of push-msg loses the
    // last press of every chunk.
    @Test func assembleLinesSplitsChunkAndCarriesIncompleteTail() {
        let first = #"{"MessagePush":{"message":"jump Safari"}}"# + "\n"
            + #"{"MessagePush":{"message":"next"}}"# + "\n"
            + #"{"MessagePush":{"mess"#
        let firstRead = KanataCommandSource.assembleLines(
            chunkBytes: Array(first.utf8)[...], incomplete: "")
        #expect(firstRead.complete.count == 2)
        #expect(firstRead.incomplete == #"{"MessagePush":{"mess"#)
        switch KanataCommandSource.parseMessage(firstRead.complete[0]) {
        case .jump(let name): #expect(name == "Safari")
        default: Issue.record("Expected .jump from the first complete line")
        }

        let second = #"age":"prev"}}"# + "\n"
        let secondRead = KanataCommandSource.assembleLines(
            chunkBytes: Array(second.utf8)[...],
            incomplete: firstRead.incomplete)
        #expect(secondRead.complete.count == 1)
        #expect(secondRead.incomplete == "")
        switch KanataCommandSource.parseMessage(secondRead.complete[0]) {
        case .prev: break
        default: Issue.record("Expected .prev from the carried tail")
        }
    }
}
