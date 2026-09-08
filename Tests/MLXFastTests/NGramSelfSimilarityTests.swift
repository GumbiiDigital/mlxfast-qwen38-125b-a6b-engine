@testable import MLXFastCore
import Testing

@Test
func ngramSelfSimilarityReportsNoHitsForUniqueContinuation() throws {
    let report = try NGramSelfSimilarity.analyze(
        contextTokens: [10, 11, 12],
        continuationTokens: [13, 14],
        orders: [1, 2, 3]
    )

    #expect(report.longestMatchOpportunityCount == 0)
    #expect(report.longestMatchMostRecentHitCount == 0)
    #expect(report.optimisticAnyOrderHitCount == 0)
    #expect(report.orders.allSatisfy { $0.mostRecentFollowerHitCount == 0 })
}

@Test
func ngramSelfSimilarityCountsEarlierMatchingFollower() throws {
    let report = try NGramSelfSimilarity.analyze(
        contextTokens: [1, 2, 3, 1, 2],
        continuationTokens: [3, 4],
        orders: [1, 2, 3]
    )

    #expect(report.longestMatchOpportunityCount == 2)
    #expect(report.longestMatchMostRecentHitCount == 1)
    #expect(report.longestMatchMostRecentHitRate == 0.5)
    let bigram = try #require(report.orders.first { $0.order == 2 })
    #expect(bigram.mostRecentFollowerHitCount == 1)
    #expect(bigram.anyMatchingFollowerHitCount == 1)
}

@Test
func ngramSelfSimilaritySeparatesRecentPredictionFromOptimisticUpperBound() throws {
    let report = try NGramSelfSimilarity.analyze(
        contextTokens: [1, 9, 1, 8, 1],
        continuationTokens: [9],
        orders: [1]
    )

    #expect(report.longestMatchOpportunityCount == 1)
    #expect(report.longestMatchMostRecentHitCount == 0)
    #expect(report.optimisticAnyOrderHitCount == 1)
    #expect(report.orders[0].mostRecentFollowerHitRate == 0)
    #expect(report.orders[0].anyMatchingFollowerHitRate == 1)
}

@Test
func ngramSelfSimilarityUsesLongestRecurrentOrder() throws {
    let report = try NGramSelfSimilarity.analyze(
        contextTokens: [2, 1, 8, 3, 1, 7, 2, 1],
        continuationTokens: [7],
        orders: [1, 2]
    )

    let unigram = try #require(report.orders.first { $0.order == 1 })
    let bigram = try #require(report.orders.first { $0.order == 2 })
    #expect(unigram.mostRecentFollowerHitCount == 1)
    #expect(bigram.mostRecentFollowerHitCount == 0)
    #expect(report.longestMatchMostRecentHitCount == 0)
    #expect(report.optimisticAnyOrderHitCount == 1)
}

@Test
func ngramSelfSimilarityNormalizesAndValidatesOrders() throws {
    let report = try NGramSelfSimilarity.analyze(
        contextTokens: [1, 2],
        continuationTokens: [3],
        orders: [3, 1, 3, 2]
    )
    #expect(report.orders.map(\.order) == [1, 2, 3])

    #expect(throws: MLXFastError.self) {
        try NGramSelfSimilarity.analyze(
            contextTokens: [],
            continuationTokens: [1],
            orders: [0]
        )
    }
    #expect(throws: MLXFastError.self) {
        try NGramSelfSimilarity.analyze(
            contextTokens: [],
            continuationTokens: [],
            orders: [1]
        )
    }
}

@Test
func ngramSelfSimilarityAppliesPassThresholdToDraftHitRate() throws {
    let report = try NGramSelfSimilarity.analyze(
        contextTokens: [1, 2, 3, 1, 2],
        continuationTokens: [3, 4],
        orders: [1, 2, 3]
    )

    #expect(report.passes(maximumHitRate: 0.5))
    #expect(!report.passes(maximumHitRate: 0.49))
    #expect(!report.passes(maximumHitRate: -.infinity))
}

// RE-MEASURED 2026-08-28 against the regenerated goldens
// (docs/qwen38-125b-a6b-port-notes.md section 5.3). This test read tokens out
// of the fixture, then asserted a provenance REFUSAL while the checked-in
// expected tokens were Gemma captures, and now reads tokens again.
//
// The thresholds are tokenizer-dependent, so they were re-measured rather than
// carried forward: `analyze-ngram-similarity --orders 1,2,3` over this
// fixture's 129-token window reports an aggregate longest-match
// most-recent-follower hit rate of 0.5813953488372093 (75/129) on the Qwen
// tokenizer, against 0.9224806201550387 under the Gemma tokenizer and 0.45736
// in the Qwen era before the 1024-seed contract.
//
// This deliberately-repetitive longcopy CORRECTNESS fixture is expected to
// FAIL the 0.03 prompt-lookup cap. That cap gates TIMED prompts, and the last
// expectation asserts the fixture would indeed be rejected as a timed target.
@Test
func currentLongcopyFixtureDemonstratesHighSelfSimilarity() throws {
    let fixture = try loadGoldenFixture(
        from: "correctness_prompts/public_longcopy_gate_english_1024_256.json"
    )
    let goldenCase = try #require(fixture.cases.first)
    let continuation = Array(
        goldenCase.expectedTokens.prefix(MLXFastConstants.benchmarkDecodeSteps + 1)
    )
    let report = try NGramSelfSimilarity.analyze(
        contextTokens: goldenCase.promptTokens,
        continuationTokens: continuation,
        orders: MLXFastConstants.benchmarkNGramSelfSimilarityOrders
    )

    #expect(report.longestMatchMostRecentHitRate > 0.25)
    #expect(report.passes(maximumHitRate: 0.59))
    #expect(!report.passes(maximumHitRate: 0.58))
    #expect(!report.passes(maximumHitRate: -.infinity))
    #expect(!report.passes(maximumHitRate: MLXFastConstants.benchmarkMaxPromptLookupHitRate))
}
