// Tests/Unit/ConfigTests.swift
import Foundation
import Testing

private func testConfig(aliases: [String: String] = [:],
                        strategies: [String: ReopenStrategy] = [:]) -> AppFocusConfig {
    AppFocusConfig(
        backend: "yabai",
        yabaiPath: "/usr/local/bin/yabai",
        aliases: aliases,
        reopenStrategies: strategies,
        pollIntervalMs: 1000,
        kanataEnabled: true,
        kanataPort: 7070)
}

@Suite("Config")
struct ConfigTests {

    // MARK: - Alias resolution

    @Test func resolveKnownAlias() {
        let config = testConfig(aliases: ["Code": "Visual Studio Code"])
        #expect(config.resolveAlias("Code") == "Visual Studio Code")
    }

    @Test func resolveUnknownAlias() {
        let config = testConfig(aliases: ["Code": "Visual Studio Code"])
        #expect(config.resolveAlias("Safari") == "Safari")
    }

    @Test func resolveEmptyAliasMap() {
        let config = testConfig()
        #expect(config.resolveAlias("Anything") == "Anything")
    }

    @Test func resolveChainDoesNotRecurse() {
        let config = testConfig(aliases: ["A": "B", "B": "C"])
        #expect(config.resolveAlias("A") == "B")
    }

    // MARK: - Reopen strategy

    @Test func reopenStrategySpecific() {
        let config = testConfig(strategies: [
            "Finder": .makeWindow,
            "*": .reopen,
        ])
        #expect(config.reopenStrategy(for: "Finder") == .makeWindow)
    }

    @Test func reopenStrategyFallsBackToWildcard() {
        let config = testConfig(strategies: ["*": .reopen])
        #expect(config.reopenStrategy(for: "Safari") == .reopen)
    }

    @Test func reopenStrategyFallsBackToReopen() {
        let config = testConfig(strategies: [:])
        #expect(config.reopenStrategy(for: "Safari") == .reopen)
    }

    // MARK: - JSON round-trip

    @Test func configDecodesWithoutKanataFields() throws {
        let json = """
        {"backend":"yabai","yabai_path":"/usr/bin/yabai","aliases":{},"reopen_strategies":{},"poll_interval_ms":500}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppFocusConfig.self, from: json)
        #expect(config.kanataEnabled == true)
        #expect(config.kanataPort == 7070)
        #expect(config.pollIntervalMs == 500)
    }

    @Test func configJsonRoundtrip() throws {
        let config = testConfig(
            aliases: ["Code": "Visual Studio Code"],
            strategies: ["Finder": .makeWindow, "*": .reopen])

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppFocusConfig.self, from: data)

        #expect(decoded.backend == config.backend)
        #expect(decoded.aliases == config.aliases)
        #expect(decoded.pollIntervalMs == config.pollIntervalMs)
    }
}
