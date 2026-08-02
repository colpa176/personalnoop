import XCTest
@testable import Strand

/// The end-of-experiment AI read. Only the PURE half is testable without a key or a network, which is
/// exactly why the prompt building is a pure function: what gets sent to a provider is the part worth
/// pinning, because it is what decides whether the reply is honest about an n-of-1 window's limits.
final class ExperimentSummarizerTests: XCTestCase {

    private func result(baseline: Double? = 62, baselineCount: Int = 14,
                        intervention: Double? = 68, interventionCount: Int = 12,
                        higherIsBetter: Bool = true,
                        duration: Int = 14, compliance: Int = 86) -> ExperimentSummarizer.Result {
        .init(title: "No screens after 10pm",
              outcomeName: "Charge", outcomeUnit: "%", higherIsBetter: higherIsBetter,
              baselineMean: baseline, baselineCount: baselineCount,
              interventionMean: intervention, interventionCount: interventionCount,
              durationDays: duration, compliancePercent: compliance)
    }

    // MARK: - Prompt contents

    func testPromptCarriesEveryNumberTheReadDependsOn() {
        let p = ExperimentSummarizer.prompt(for: result())
        XCTAssertTrue(p.contains("No screens after 10pm"))
        XCTAssertTrue(p.contains("Charge"))
        XCTAssertTrue(p.contains("62.0 %"))
        XCTAssertTrue(p.contains("68.0 %"))
        XCTAssertTrue(p.contains("14 days"))
        XCTAssertTrue(p.contains("12 days"))
        XCTAssertTrue(p.contains("86%"))
    }

    /// The model cannot infer that a LOWER resting HR is the better one, so the direction has to be
    /// stated — otherwise a good result reads as a bad one.
    func testPromptStatesWhichDirectionIsBetter() {
        XCTAssertTrue(ExperimentSummarizer.prompt(for: result(higherIsBetter: true)).contains("HIGHER number is better"))
        XCTAssertTrue(ExperimentSummarizer.prompt(for: result(higherIsBetter: false)).contains("LOWER number is better"))
    }

    func testPromptComputesTheSignedDifference() {
        XCTAssertTrue(ExperimentSummarizer.prompt(for: result()).contains("+6.0"))
        XCTAssertTrue(ExperimentSummarizer.prompt(for: result(baseline: 68, intervention: 62)).contains("-6.0"))
    }

    /// A missing side must be said plainly rather than silently becoming a zero the model would then
    /// describe as a real change.
    func testPromptSaysWhenASideHasNoDays() {
        let p = ExperimentSummarizer.prompt(for: result(intervention: nil, interventionCount: 0))
        XCTAssertTrue(p.contains("not enough data"))
        XCTAssertTrue(p.contains("cannot be computed"))
        XCTAssertFalse(p.contains("+0.0"), "an absent side must not read as a zero difference")
    }

    /// One decimal, not a float tail: handing over 61.99999999 invites the model to echo a precision
    /// the measurement never had.
    func testPromptRoundsToOneDecimal() {
        let p = ExperimentSummarizer.prompt(for: result(baseline: 61.99999999, intervention: 68.04))
        XCTAssertTrue(p.contains("62.0 %"))
        XCTAssertTrue(p.contains("68.0 %"))
        XCTAssertFalse(p.contains("61.99999999"))
    }

    /// Pure and deterministic — no clock, no locale — so this pin can't go green-then-red on its own.
    func testPromptIsDeterministic() {
        XCTAssertEqual(ExperimentSummarizer.prompt(for: result()),
                       ExperimentSummarizer.prompt(for: result()))
    }

    // MARK: - System prompt guardrails

    /// The single failure that matters: an uncontrolled, unblinded, single-subject before-and-after
    /// window cannot establish cause, and a model asked to "analyse an experiment" will write causal
    /// prose unless told not to. These pin that the instruction is actually present.
    func testSystemPromptForbidsCausalLanguageAndMedicalAdvice() {
        let s = ExperimentSummarizer.systemPrompt
        XCTAssertTrue(s.contains("CANNOT establish"))
        XCTAssertTrue(s.contains("caused"))
        XCTAssertTrue(s.lowercased().contains("never diagnose"))
        XCTAssertTrue(s.lowercased().contains("medical advice"))
    }

    /// "This shows nothing yet" has to be an allowed answer, or the model will invent a finding.
    func testSystemPromptPermitsANullResult() {
        XCTAssertTrue(ExperimentSummarizer.systemPrompt.contains("does not show anything you"))
        XCTAssertTrue(ExperimentSummarizer.systemPrompt.contains("Do not manufacture an insight"))
    }
}
