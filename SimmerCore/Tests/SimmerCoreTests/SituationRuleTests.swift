import XCTest
@testable import SimmerCore

final class SituationRuleTests: XCTestCase {
    private let desk = Situation(adapterWatts: 96, externalDisplayCount: 1)
    private let travel = Situation(adapterWatts: 30, externalDisplayCount: 0)
    private let battery = Situation(adapterWatts: nil, externalDisplayCount: 0)

    func testConditionsMatchTheSituation() {
        XCTAssertTrue(SituationCondition.adapter(watts: 96).matches(desk))
        XCTAssertFalse(SituationCondition.adapter(watts: 96).matches(travel))
        XCTAssertFalse(SituationCondition.adapter(watts: 96).matches(battery))
        XCTAssertTrue(SituationCondition.externalDisplay.matches(desk))
        XCTAssertFalse(SituationCondition.externalDisplay.matches(travel))
        XCTAssertTrue(SituationCondition.pluggedInWithoutDisplay.matches(travel))
        XCTAssertFalse(SituationCondition.pluggedInWithoutDisplay.matches(desk))
        XCTAssertFalse(SituationCondition.pluggedInWithoutDisplay.matches(battery))
    }

    func testFirstEnabledMatchingRuleWins() {
        let rules = [
            SituationRule(isEnabled: false, condition: .externalDisplay, limit: 50),
            SituationRule(condition: .adapter(watts: 96), limit: 60),
            SituationRule(condition: .externalDisplay, limit: 70),
        ]
        XCTAssertEqual(rules.active(in: desk)?.limit, 60)
        XCTAssertNil(rules.active(in: travel))
        XCTAssertNil([SituationRule]().active(in: desk))
    }

    func testRuleLimitIsClamped() {
        XCTAssertEqual(SituationRule(condition: .externalDisplay, limit: 5).effectiveLimit, 20)
        XCTAssertEqual(SituationRule(condition: .externalDisplay, limit: 150).effectiveLimit, 100)
    }

    func testRulesSurviveASettingsRoundTripAndOldSettingsDecode() throws {
        var settings = SimmerSettings()
        settings.situationRules = [SituationRule(condition: .adapter(watts: 65), limit: 60)]
        let decoded = try JSONDecoder().decode(SimmerSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.situationRules, settings.situationRules)
        let old = try JSONDecoder().decode(SimmerSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(old.situationRules.isEmpty)
    }

    @MainActor
    func testModelAppliesTheActiveRuleWithoutChangingTheNormalLimit() async {
        let suite = "simmer-situation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let displays = DisplayCount()
        let model = SimmerModel(
            store: SettingsStore(defaults: defaults),
            readSnapshot: { BatterySnapshot(percent: 70, isPluggedIn: true, adapterWatts: 65) },
            makeController: { _, _ in DryRunChargeController() },
            countExternalDisplays: { displays.value }
        )
        model.settings.situationRules = [SituationRule(condition: .externalDisplay, limit: 60)]

        await model.tick(now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(model.activeSituationRule)
        XCTAssertEqual(model.effectiveLimit, 80)
        XCTAssertEqual(model.appliedCommand?.chargingAllowed, true, "70 % is below the normal 80 % limit")

        displays.value = 1
        await model.tick(now: Date(timeIntervalSince1970: 1_800_000_010))
        XCTAssertEqual(model.situation, Situation(adapterWatts: 65, externalDisplayCount: 1))
        XCTAssertEqual(model.effectiveLimit, 60)
        XCTAssertEqual(model.settings.engine.limit, 80, "the normal limit is untouched")
        XCTAssertEqual(model.appliedCommand?.chargingAllowed, false, "70 % is above the rule's 60 % limit")
    }
}

@MainActor
private final class DisplayCount {
    var value = 0
}
