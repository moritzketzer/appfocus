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
}
