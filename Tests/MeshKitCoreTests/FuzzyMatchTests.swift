import Testing
@testable import MeshKitCore

@Suite struct FuzzyMatchTests {
    private let fields = ["Seeed Wio Tracker L1", "WioTrackerL1", "Seeed Studio"]

    @Test(arguments: ["seeed", "wio", "wio l1", "tracker l1", "studio tracker", "SEEED", "wtl1", "wiotrak", "seed"])
    func matches(query: String) {
        #expect(FuzzyMatch.score(query, in: fields) != nil, "\(query)")
    }

    @Test(arguments: ["heltec", "rak", "xyz", "wio rak", "trackxyz"])
    func doesNotMatch(query: String) {
        #expect(FuzzyMatch.score(query, in: fields) == nil, "\(query)")
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(FuzzyMatch.score("  ", in: fields) == 0)
    }

    @Test func wordStartsOutrankLooseMatches() throws {
        let strong = try #require(FuzzyMatch.score("heltec", in: ["Heltec V3"]))
        let loose = try #require(FuzzyMatch.score("hltc", in: ["Heltec V3"]))
        #expect(strong > loose)
    }

    @Test func ignoresPunctuationAndAccents() {
        #expect(FuzzyMatch.score("tbeam", in: ["LilyGo T-Beam"]) != nil)
        #expect(FuzzyMatch.score("cafe", in: ["Café"]) != nil)
    }
}
