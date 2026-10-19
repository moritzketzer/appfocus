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
            chunkBytes: Array(first.utf8)[...], incomplete: [])
        #expect(firstRead.complete.count == 2)
        #expect(firstRead.incomplete == Array(#"{"MessagePush":{"mess"#.utf8))
        switch KanataCommandSource.parseMessage(firstRead.complete[0]) {
        case .jump(let name): #expect(name == "Safari")
        default: Issue.record("Expected .jump from the first complete line")
        }

        let second = #"age":"prev"}}"# + "\n"
        let secondRead = KanataCommandSource.assembleLines(
            chunkBytes: Array(second.utf8)[...],
            incomplete: firstRead.incomplete)
        #expect(secondRead.complete.count == 1)
        #expect(secondRead.incomplete.isEmpty)
        switch KanataCommandSource.parseMessage(secondRead.complete[0]) {
        case .prev: break
        default: Issue.record("Expected .prev from the carried tail")
        }
    }

    // A read boundary can fall INSIDE a multi-byte UTF-8 character. Decoding
    // the raw chunk would fail there, so the tail has to be carried as bytes:
    // a String tail cannot express half a character and the whole envelope
    // (the press) was lost.
    @Test func assembleLinesSurvivesMultiByteCharacterSplitAcrossReads() {
        let envelope = #"{"MessagePush":{"message":"jump Köln"}}"# + "\n"
        let bytes = Array(envelope.utf8)
        // 0xC3 is the lead byte of "ö"; the first read ends on it.
        let leadIndex = bytes.firstIndex(of: 0xC3) ?? 0
        let first = KanataCommandSource.assembleLines(
            chunkBytes: bytes[0...leadIndex], incomplete: [])
        #expect(first.complete.isEmpty)

        let second = KanataCommandSource.assembleLines(
            chunkBytes: bytes[(leadIndex + 1)...], incomplete: first.incomplete)
        #expect(second.complete.count == 1)
        switch KanataCommandSource.parseMessage(second.complete.first ?? "") {
        case .jump(let name): #expect(name == "Köln")
        default: Issue.record("Expected .jump reassembled across the split character")
        }
    }

    // Garbage on the wire must cost exactly its own line: decoding the chunk
    // as one unit threw away every envelope that shared the read.
    @Test func assembleLinesDropsOnlyTheUndecodableLine() {
        var bytes = Array(#"{"MessagePush":{"message":"jump "#.utf8)
        bytes.append(0xFF)  // never valid UTF-8
        bytes.append(contentsOf: Array(#""}}"#.utf8))
        bytes.append(0x0A)
        bytes.append(contentsOf: Array((#"{"MessagePush":{"message":"next"}}"# + "\n").utf8))

        let assembled = KanataCommandSource.assembleLines(
            chunkBytes: bytes[...], incomplete: [])
        #expect(assembled.complete.count == 1)
        switch KanataCommandSource.parseMessage(assembled.complete.first ?? "") {
        case .next: break
        default: Issue.record("The valid line must survive its undecodable neighbour")
        }
    }
}
