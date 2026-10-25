import Foundation
import Testing
@testable import MeshKitCore

@Suite struct ConvertTests {
    @Test func shortNameIsTheInitialsOfSeveralWordsOrTheStartOfOne() {
        #expect(NodeIdentity(name: "MeshKit Test").shortName == "MT")
        #expect(NodeIdentity(name: "North Ridge Repeater One").shortName == "NRRO")
        #expect(NodeIdentity(name: "Basecamp").shortName == "BASE")
        #expect(NodeIdentity(name: "").shortName == "")
    }

    @Test func aLocationOfZeroOrOutOfRangeMeansNoLocation() {
        #expect(!NodeIdentity(name: "a", latitude: 0, longitude: 0).hasLocation)
        #expect(!NodeIdentity(name: "a", latitude: 91, longitude: 0).hasLocation)
        #expect(!NodeIdentity(name: "a", latitude: 12, longitude: nil).hasLocation)
        let identity = NodeIdentity(name: "a", latitude: 12.5, longitude: -45.25)
        #expect(identity.hasLocation && identity.summary.contains("12.50000"))
    }

    @Test func boardsPairBothWays() {
        #expect(BoardPairs.meshtasticSlug(forMeshCoreBoard: "WioTrackerL1") == "seeed_wio_tracker_L1")
        #expect(BoardPairs.meshtasticSlug(forMeshCoreBoard: "heltec_t096") == "heltec-mesh-node-t096")
        #expect(BoardPairs.meshCoreSlug(forMeshtasticBoard: "seeed_wio_tracker_l1") == "wiotrackerl1")
        #expect(BoardPairs.meshtasticSlug(forMeshCoreBoard: "Heltec_v2") == nil)
    }

    @Test func carriesTheNameAndLocationToAMeshtasticNode() async throws {
        let node = SimulatedMeshtasticNode()
        let identity = NodeIdentity(name: "Hilltop Relay", latitude: 12.5, longitude: -45.25)
        try await IdentityTransfer.carryOver(identity, toMeshtasticAt: { node }, attempts: 1, pause: .zero)
        #expect(node.currentOwner.longName == "Hilltop Relay" && node.currentOwner.shortName == "HR")
        let fixed = try #require(node.fixedPosition)
        #expect(abs(fixed.latitude - 12.5) < 1e-6 && abs(fixed.longitude + 45.25) < 1e-6)
    }

    @Test func carriesTheNameAndLocationToACompanion() async throws {
        let node = SimulatedCompanionTransport(name: "Fresh")
        try await IdentityTransfer.carryOver(NodeIdentity(name: "Hilltop Relay", latitude: 12.5, longitude: -45.25), toCompanionAt: { node },
                                             attempts: 1, pause: .zero)
        #expect(node.currentSelf.name == "Hilltop Relay")
        #expect(abs(node.currentSelf.latitude - 12.5) < 1e-5 && abs(node.currentSelf.longitude + 45.25) < 1e-5)
    }

    @Test func aBoardThatNeverAnswersIsReported() async {
        final class Silent: ByteTransport, @unchecked Sendable {
            private let broadcaster = DataBroadcaster()
            func subscribe() -> AsyncStream<Data> { broadcaster.subscribe() }
            func send(_ data: Data) async throws {}
            func close() {}
        }
        await #expect(throws: IdentityTransfer.TransferError.self) {
            try await IdentityTransfer.carryOver(NodeIdentity(name: "x"), toMeshtasticAt: { Silent() }, attempts: 1, pause: .zero)
        }
    }
}

@Suite struct NameLimitTests {
    @Test func limitsAreCountedInBytes() {
        #expect(NameLimits.meshCore == 31 && NameLimits.meshtasticLong == 39 && NameLimits.meshtasticShort == 4)
        #expect(NameLimits.meshCore(sharingLocation: true) == 23 && NameLimits.meshCore(sharingLocation: false) == 31)
        #expect(NameLimits.used("é") == 2)
    }

    @Test func fitNeverCutsACharacterInHalf() {
        #expect(NameLimits.fit("abc", bytes: 5) == "abc")
        #expect(NameLimits.fit("abcdef", bytes: 4) == "abcd")
        let accented = String(repeating: "é", count: 40)
        let fitted = NameLimits.fit(accented, bytes: 31)
        #expect(fitted.utf8.count == 30 && fitted.allSatisfy { $0 == "é" })
        #expect(NameLimits.fit("日本語", bytes: 4) == "日")
        #expect(NameLimits.fit("x", bytes: 0) == "")
    }

    @Test func aLongMeshtasticNameIsShortenedForMeshCore() {
        let long = String(repeating: "n", count: 39)
        let identity = NodeIdentity(name: long, latitude: 1, longitude: 2)
        #expect(!identity.nameFitsMeshCore)
        let fitted = identity.fitted(toBytes: NameLimits.meshCore)
        #expect(fitted.name.utf8.count == 31 && fitted.latitude == 1 && fitted.nameFitsMeshCore)
        #expect(identity.fitted(toBytes: NameLimits.meshtasticLong).name == long)
    }

    @Test func aLocationOnlyShortensTheAdvertisedNameWhenItIsShared() {
        let between = NodeIdentity(name: String(repeating: "n", count: 28), latitude: 1, longitude: 2)
        #expect(between.nameFitsMeshCore && between.exceedsLocationAdvertLimit)
        #expect(!NodeIdentity(name: String(repeating: "n", count: 28)).exceedsLocationAdvertLimit)
        #expect(!NodeIdentity(name: "short", latitude: 1, longitude: 2).exceedsLocationAdvertLimit)
    }

    @Test func repeatersAreHeldToTheAdvertisedLength() {
        #expect(NameLimits.meshCoreRepeater == 23 && NameLimits.meshCoreRepeater == NameLimits.meshCoreAdvertised)
    }

    @Test func theShortNameStaysWithinFourBytes() {
        #expect(NodeIdentity(name: "North Ridge Repeater One").shortName.utf8.count <= 4)
        #expect(NodeIdentity(name: "Éric Éric Éric").shortName.utf8.count <= 4)
    }
}

@Suite struct LocationSharingTests {
    @Test func theOtherParamsCommandCarriesAllFourValues() {
        #expect(CompanionRequest.setOtherParams(manualAddContacts: true, telemetryModes: 0x15, shareLocation: true, multiAcks: false) == [38, 1, 0x15, 1, 0])
        #expect(CompanionRequest.setOtherParams(manualAddContacts: false, telemetryModes: 0, shareLocation: false, multiAcks: true) == [38, 0, 0, 0, 1])
    }

    @Test func turningSharingOnAndOffReachesTheNodeAndKeepsItsOtherSettings() async throws {
        let node = SimulatedCompanionTransport(name: "Fresh")
        let client = CompanionClient(transport: node)
        await client.start()
        let (_, me) = try await client.handshake()
        try await client.setLocationSharing(!me.advertLocationShared, current: me)
        #expect(node.currentSelf.advertLocationShared == !me.advertLocationShared)
        #expect(node.currentSelf.manualAddContacts == me.manualAddContacts && node.currentSelf.telemetryModes == me.telemetryModes && node.currentSelf.multiAcks == me.multiAcks)
        try await client.setLocationSharing(me.advertLocationShared, current: node.currentSelf)
        #expect(node.currentSelf.advertLocationShared == me.advertLocationShared)
        await client.stop()
    }
}

@Suite struct ESPBoardPairTests {
    @Test func theHeltecV3PairsBothWays() {
        #expect(BoardPairs.meshtasticSlug(forMeshCoreBoard: "Heltec_v3") == "heltec-v3")
        #expect(BoardPairs.meshCoreSlug(forMeshtasticBoard: "heltec-v3") == "Heltec_v3")
        #expect(BoardPairs.meshtasticSlug(forMeshCoreBoard: "heltec_v4") == "heltec-v4")
    }

    @Test func everyPairedNameMatchesWhenCaseAndPunctuationAreIgnored() {
        let norm: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        for (core, tastic) in BoardPairs.espPairs { #expect(norm(core) == norm(tastic), "\(core) vs \(tastic)") }
    }

    @Test func aBoardWithDifferentNamesIsNotPaired() {
        #expect(BoardPairs.meshtasticSlug(forMeshCoreBoard: "LilyGo_TDeck") == nil)
        #expect(BoardPairs.meshCoreSlug(forMeshtasticBoard: "t-deck") == nil)
    }
}

@Suite struct USBNameTests {
    @Test func aBridgeChipNameIsNotABoardName() {
        #expect(USBNameAliases.isGeneric("CP2102 USB to UART Bridge Controller"))
        #expect(USBNameAliases.isGeneric("USB Serial"))
        #expect(!USBNameAliases.isGeneric("HT-n5262G") && !USBNameAliases.isGeneric("Seeed Wio Tracker L1"))
        #expect(USBNameAliases.boardName(forUSBName: "HT-n5262G") == "Heltec T096")
    }
}

@Suite struct CarryOverVerificationTests {
    private func me(name: String, lat: Double, lon: Double) -> SelfInfo {
        SimulatedCompanionTransport(name: name).currentSelf.with { $0.latitude = lat; $0.longitude = lon }
    }

    @Test func aBoardThatKeptTheValuesPasses() {
        let identity = NodeIdentity(name: "Hilltop", latitude: 41.9, longitude: -87.65)
        #expect(IdentityTransfer.verified(me(name: "Hilltop", lat: 41.9, lon: -87.65), matches: identity))
    }

    @Test func aBoardThatLostTheNameOrTheLocationFails() {
        let identity = NodeIdentity(name: "Hilltop", latitude: 41.9, longitude: -87.65)
        #expect(!IdentityTransfer.verified(me(name: "CA02CEF8", lat: 41.9, lon: -87.65), matches: identity))
        #expect(!IdentityTransfer.verified(me(name: "Hilltop", lat: 0, lon: 0), matches: identity))
        #expect(IdentityTransfer.verified(me(name: "Anything", lat: 0, lon: 0), matches: NodeIdentity(name: "")))
    }
}

@Suite struct RepeaterCarryOverTests {
    @Test func nameAndLocationAreSetAndReadBack() async throws {
        let sim = SimulatedRepeaterTransport()
        let identity = NodeIdentity(name: "Hilltop", latitude: 41.9, longitude: -87.65)
        try await IdentityTransfer.carryOver(identity, toRepeaterAt: { sim }, attempts: 1)
        let client = RepeaterCLIClient(transport: sim)
        await client.start()
        #expect(try await client.read(CLICatalog.setting("name")!) == .value("Hilltop"))
        #expect(try await client.read(CLICatalog.setting("lat")!) == .value("41.9"))
        await client.stop()
    }

    @Test func forbiddenCharactersAreReplacedForARepeater() {
        #expect(NameLimits.repeaterSafe("Hilltop, North: [A]") == "Hilltop North A")
        #expect(NameLimits.repeaterSafe("Plain name") == "Plain name")
        #expect(NameLimits.repeaterSafe("a\\b?c*d") == "a b c d")
        #expect(NameLimits.repeaterForbiddenCharacters(in: "x, y, z:") == [",", ":"])
        let id = NodeIdentity(name: "Hilltop, North Ridge Repeater Number One").fittedForRepeater()
        #expect(id.name.utf8.count <= 23 && !id.name.contains(","))
    }

    @Test func aDeviceErrorIsRaisedWhateverTheCase() async throws {
        let sim = SimulatedRepeaterTransport()
        let client = RepeaterCLIClient(transport: sim)
        await client.start()
        // The simulator answers "Error: unknown config", as firmware answers "Error, bad chars".
        await #expect(throws: RepeaterCLIClient.DeviceError.self) { try await client.runChecked("set bogus.setting 1") }
        await client.stop()
    }

    @Test func aStrayFirstLineIsNotPartOfTheVersion() {
        #expect(RepeaterCLIClient.lastLine("Unknown command\nver\nv1.18.0-81dbae5 (Build: 15-Oct-2026)") == "v1.18.0-81dbae5 (Build: 15-Oct-2026)")
        #expect(RepeaterCLIClient.lastLine("Heltec V3") == "Heltec V3")
        #expect(RepeaterCLIClient.lastLine("") == "")
    }

    @Test func repeatersAreHeldToTwentyThreeBytes() {
        let long = NodeIdentity(name: String(repeating: "é", count: 20))
        #expect(long.fitted(toBytes: NameLimits.meshCoreRepeater).name.utf8.count <= 23)
    }
}

private extension SelfInfo {
    func with(_ change: (inout SelfInfo) -> Void) -> SelfInfo { var copy = self; change(&copy); return copy }
}
