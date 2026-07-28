import Foundation
import StrandImport

// MARK: - Food text → estimated macros
//
// The bridge between the food log's text field and whatever provider the user already configured for
// Coach. It is deliberately thin: the prompt and the reply parsing both live in `StrandImport`'s pure
// `FoodTextEstimator`, where `swift test` can exercise them with no key, no network and no app. All this
// layer does is carry a string there and back.
//
// No new network surface. If Coach is not connected, `estimate` returns a `.notConfigured` outcome and
// the card falls back to a manual calories+macros form, so logging food never depends on an API key.

/// What came back from an estimate attempt. Distinguishes "no provider" from "the provider answered but
/// the answer was unusable", because those want different words in the UI — one is a setup state, the
/// other is a retry-or-type-it-yourself state.
enum FoodEstimateOutcome {
    case estimated(FoodTextEstimate)
    /// No Coach provider is connected. Not an error: the manual path is a first-class way to log.
    case notConfigured
    /// The provider replied, but nothing usable could be read out of it (prose, an apology, `{}`, or a
    /// truncated object). The user's text is kept; they finish in the manual form.
    case unusableReply
    /// The request itself failed. Carries the provider's own message so the card can show it verbatim.
    case failed(String)
}

enum FoodLogEstimator {

    /// System prompt for the estimate call. Narrow on purpose — this is a one-shot extraction task, not
    /// a coaching turn, so it says nothing about training, readiness, or the user at all.
    static let systemPrompt = """
    You are a nutrition estimation tool. You convert a short description of food into approximate \
    energy and macronutrient values. You reply with JSON only — no prose, no code fence, no commentary. \
    You never guess a value you cannot reasonably estimate; you omit that key instead.
    """

    /// Ask the configured provider to estimate the macros for `text`.
    ///
    /// Never throws and never crashes: every failure path resolves to an outcome the card can render,
    /// because a nutrition estimate is a convenience and must never be able to block logging what you ate.
    @MainActor
    static func estimate(text: String, coach: AICoachEngine) async -> FoodEstimateOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unusableReply }
        guard coach.isConfigured else { return .notConfigured }

        do {
            let reply = try await coach.complete(systemPrompt: systemPrompt,
                                                 userText: FoodTextEstimator.prompt(for: trimmed))
            guard let estimate = FoodTextEstimator.parse(reply) else { return .unusableReply }
            return .estimated(estimate)
        } catch let e as AICoachError {
            // `.noKey` can still surface here if the key was cleared between the check above and the
            // send; report it as the setup state it is, not as a failure.
            if case .noKey = e { return .notConfigured }
            return .failed(e.errorDescription ?? String(localized: "The estimate failed."))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
