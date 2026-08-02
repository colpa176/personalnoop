import Foundation

// MARK: - Experiment result → plain-English comparison
//
// The end-of-experiment read: hand the finished n-of-1 numbers (baseline mean vs intervention mean, the
// day counts, the compliance) to whichever provider the user already configured for Coach, and get back
// a few sentences about what — if anything — the window showed.
//
// Thin, exactly like `FoodLogEstimator`: no new network surface, no new key, and the prompt building is
// a pure function so `swift test` can pin its wording with no key, no network and no app. If Coach is
// not connected the card keeps the numeric read it already showed; the AI sentence is a bonus on top of
// a result that is complete without it, never the only way to see the outcome.
//
// The system prompt is deliberately strict about the ONE failure that matters here. An n-of-1 window of
// a week or two, uncontrolled and unblinded, cannot establish that a behaviour caused an outcome — and a
// model asked to "analyse an experiment" will happily write causal, confident prose anyway. So it is
// told the design's limits explicitly, told to name them, and told to say plainly when the honest answer
// is "this shows nothing yet".
enum ExperimentSummarizer {

    /// What came back. Distinguishes "no provider" (a setup state — the numeric read is still there)
    /// from a real failure, because those want different words on the card.
    enum Outcome {
        case summarized(String)
        /// No Coach provider is connected. Not an error: the numbers above stand on their own.
        case notConfigured
        /// The request failed. Carries the provider's own message so the card can show it verbatim.
        case failed(String)
    }

    /// The numbers a summary is built from. A plain struct rather than the view's private snapshot so
    /// the prompt builder is testable without constructing a SwiftUI view.
    struct Result: Equatable {
        let title: String
        let outcomeName: String
        let outcomeUnit: String
        /// Whether a HIGHER outcome value is the better one — the model cannot infer this for RHR.
        let higherIsBetter: Bool
        let baselineMean: Double?
        let baselineCount: Int
        let interventionMean: Double?
        let interventionCount: Int
        let durationDays: Int
        let compliancePercent: Int
    }

    static let systemPrompt = """
    You are helping someone read the result of their own single-person self-experiment. You are not a \
    doctor and you never diagnose, prescribe, or give medical advice.

    The design is a single subject, uncontrolled, unblinded, non-randomised before-and-after comparison \
    over a short window. That design CANNOT establish that the behaviour caused the change. Say so in \
    your own words rather than quoting this back. Never write that something "caused", "improved" or \
    "boosted" the outcome; write about what the numbers show and what could equally explain them \
    (normal week-to-week variation, seasonality, an illness, a change in sleep or training, the placebo \
    effect, or simply paying more attention).

    Be direct about weak evidence. If the day counts are small, the difference is tiny relative to \
    normal variation, or compliance was poor, lead with that — "this window does not show anything you \
    can rely on" is the honest and useful answer, not a failure. Do not manufacture an insight.

    Reply in 3 to 5 short sentences of plain prose. No headings, no bullet points, no markdown, no \
    preamble. Address the person as "you".
    """

    /// The user-turn prompt for one finished experiment. Pure and deterministic — no dates, no clock, no
    /// locale-dependent formatting — so a test can pin it exactly.
    ///
    /// Numbers are pre-rounded to one decimal here rather than handed over raw: a float tail invites the
    /// model to echo a precision the measurement never had.
    static func prompt(for r: Result) -> String {
        func num(_ v: Double?) -> String {
            guard let v else { return "not enough data" }
            return String(format: "%.1f", v) + (r.outcomeUnit.isEmpty ? "" : " " + r.outcomeUnit)
        }
        let direction = r.higherIsBetter
            ? "For this outcome, a HIGHER number is better."
            : "For this outcome, a LOWER number is better."
        var lines = [
            "Experiment: \(r.title)",
            "Outcome measured: \(r.outcomeName)",
            direction,
            "Baseline (days before the experiment, without the behaviour): \(num(r.baselineMean)) "
                + "across \(r.baselineCount) days",
            "During the experiment (days the behaviour was logged): \(num(r.interventionMean)) "
                + "across \(r.interventionCount) days",
            "Planned window: \(r.durationDays) days",
            "Compliance: \(r.compliancePercent)% of days logged",
        ]
        if let b = r.baselineMean, let i = r.interventionMean {
            let delta = i - b
            let sign = delta >= 0 ? "+" : "-"
            lines.append("Difference (during minus baseline): \(sign)\(String(format: "%.1f", abs(delta)))")
        } else {
            lines.append("Difference: cannot be computed — one side has no days.")
        }
        lines.append("")
        lines.append("Tell me what this window does and does not show.")
        return lines.joined(separator: "\n")
    }

    /// Ask the configured provider to read the result.
    ///
    /// Never throws: every failure path resolves to an outcome the card can render, because the numeric
    /// read is already on screen and an AI sentence must never be able to break it.
    @MainActor
    static func summarize(_ result: Result, coach: AICoachEngine) async -> Outcome {
        guard coach.isConfigured else { return .notConfigured }
        do {
            let reply = try await coach.complete(systemPrompt: systemPrompt,
                                                 userText: prompt(for: result))
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .failed(String(localized: "The summary came back empty.")) : .summarized(trimmed)
        } catch let e as AICoachError {
            // `.noKey` can still surface if the key was cleared between the check above and the send.
            if case .noKey = e { return .notConfigured }
            return .failed(e.errorDescription ?? String(localized: "The summary failed."))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
