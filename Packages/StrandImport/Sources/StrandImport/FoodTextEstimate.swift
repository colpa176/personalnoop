import Foundation

// MARK: - Text → macros: the prompt, and the parser for what comes back
//
// The manual food-log path lets the user type what they ate ("chicken breast and rice for lunch") and,
// when a Coach provider is configured, asks that model for an estimate of the calories and macros.
//
// Everything in this file is PURE: it builds a prompt string and parses a reply string. No network, no
// store, no provider client. That is deliberate — the fragile part of an LLM feature is not the HTTP
// call, it is trusting whatever text comes back, and that part has to be testable with `swift test`,
// with no key, no server and no app. The app layer (`FoodLogEstimator`) does nothing but carry the
// string to the user's chosen provider and hand the reply back here.
//
// The parser assumes a hostile-ish reply on purpose. Models wrap JSON in prose, in ``` fences, emit
// numbers as strings with units, invent extra keys, or answer with an apology and no JSON at all. Every
// one of those must degrade to "no estimate" (which drops the user into the manual form), never to a
// wrong number presented as a real one.

/// An estimate of one logged food entry's energy and macros. Every field is optional: a model that
/// could not resolve a value must leave it absent rather than have a 0 invented on its behalf.
public struct FoodTextEstimate: Sendable, Equatable {
    /// A short tidy-up of what was eaten, if the model offered one. Never replaces the user's own text;
    /// it is only ever shown as a secondary label.
    public var label: String?
    public var kcal: Double?
    public var proteinG: Double?
    public var carbsG: Double?
    public var fatG: Double?

    public init(label: String? = nil, kcal: Double? = nil, proteinG: Double? = nil,
                carbsG: Double? = nil, fatG: Double? = nil) {
        self.label = label
        self.kcal = kcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
    }

    /// True when at least one number came back. An estimate with none is worthless to store, so the
    /// caller treats it as a failed parse and falls back to the manual form.
    public var hasAnyValue: Bool {
        kcal != nil || proteinG != nil || carbsG != nil || fatG != nil
    }
}

public enum FoodTextEstimator {

    // MARK: - Plausibility bounds
    //
    // A model that misreads "a bowl of rice" as a bulk order can return 250000 kcal, and storing that
    // would wreck the day's totals and every chart downstream. These bounds are deliberately generous —
    // they exist to reject nonsense, not to second-guess a big but real meal — and an out-of-range value
    // is DROPPED (left absent), never clamped: clamping 250000 to 10000 would still be a fabricated
    // number, just a less obvious one.

    /// Upper bound for a single entry's energy. A genuine single log is far below this; anything above
    /// is a parsing or unit error, not a meal.
    public static let maxKcal: Double = 10_000
    /// Upper bound for a single entry's grams of any one macro.
    public static let maxMacroGrams: Double = 2_000

    // MARK: - Prompt

    /// Instruction sent alongside the user's text. Asks for JSON only, names the exact keys, and — the
    /// part that matters most — tells the model to OMIT a field it cannot estimate rather than guess a
    /// number, which is what keeps "unknown" distinguishable from "zero" all the way down to the column.
    public static func prompt(for text: String) -> String {
        """
        Estimate the nutrition of the food described below.

        Reply with ONE JSON object and nothing else — no prose, no code fence, no explanation.
        Use exactly these keys:
          "label"     — a short name for the food (string)
          "kcal"      — total energy in kilocalories (number)
          "protein_g" — grams of protein (number)
          "carbs_g"   — grams of carbohydrate (number)
          "fat_g"     — grams of fat (number)

        Estimate for the WHOLE described portion, not per 100 g. Use plain numbers with no units and no
        ranges. If a value genuinely cannot be estimated, OMIT that key entirely — do not guess, and do
        not use 0 to mean "unknown". If the text does not describe food at all, reply with {}.

        Food: \(text)
        """
    }

    // MARK: - Parsing

    /// Parse a model reply into an estimate. Returns nil when no usable numbers could be read — the
    /// caller's cue to fall back to the manual entry form. Tolerant of the usual model habits: ``` code
    /// fences, prose either side of the JSON, numbers sent as strings ("620", "620 kcal"), and key
    /// aliases ("calories" for "kcal").
    public static func parse(_ reply: String) -> FoodTextEstimate? {
        guard let json = firstJSONObject(in: reply),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let dict = object as? [String: Any]
        else { return nil }

        // Case/underscore-insensitive lookup, so "Calories", "calories" and "calories_kcal" all land.
        var normalized: [String: Any] = [:]
        for (k, v) in dict { normalized[normalizeKey(k)] = v }

        var estimate = FoodTextEstimate()
        if let raw = (normalized["label"] as? String) ?? (normalized["name"] as? String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            estimate.label = trimmed.isEmpty ? nil : trimmed
        }

        estimate.kcal = number(normalized, keys: ["kcal", "calories", "energy", "energykcal", "caloriesin"],
                               max: maxKcal)
        estimate.proteinG = number(normalized, keys: ["proteing", "protein"], max: maxMacroGrams)
        estimate.carbsG = number(normalized, keys: ["carbsg", "carbs", "carbohydrates", "carbohydrateg",
                                                    "carbohydrate"], max: maxMacroGrams)
        estimate.fatG = number(normalized, keys: ["fatg", "fat", "totalfat"], max: maxMacroGrams)

        return estimate.hasAnyValue ? estimate : nil
    }

    /// Lower-cased with separators stripped, so "protein_g", "Protein (g)" and "proteinG" all normalize
    /// to one lookup key.
    static func normalizeKey(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// First present key that yields a usable number. A value outside `0...max`, non-finite, or
    /// unparseable is skipped rather than clamped — see the bounds note above.
    private static func number(_ dict: [String: Any], keys: [String], max: Double) -> Double? {
        for key in keys {
            guard let raw = dict[key], let v = coerceNumber(raw) else { continue }
            guard v.isFinite, v >= 0, v <= max else { continue }
            return v
        }
        return nil
    }

    /// Coerce a JSON value to a Double. Handles real numbers, numeric strings, and strings carrying a
    /// unit or stray text ("620 kcal", "~35g"). Explicit null, booleans and ranges ("400-600") are
    /// rejected: a range is not an estimate, and picking an end of it would be inventing precision.
    static func coerceNumber(_ raw: Any) -> Double? {
        // JSONSerialization hands back every number as NSNumber, so this branch covers ints and doubles
        // alike. Booleans arrive as the distinct __NSCFBoolean, identified by CoreFoundation type id —
        // NOT by `is Bool`, which succeeds for any NSNumber whose value is 0 or 1 and would therefore
        // have thrown away a legitimate `"fat_g": 0`, turning a recorded zero into "unknown".
        if let n = raw as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.doubleValue
        }
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        guard let s = raw as? String else { return nil }

        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A range ("400-600", "400 to 600") is ambiguous; refuse rather than pick a side. A leading
        // minus is handled by the >= 0 bound in `number`, so only an INNER dash means a range.
        let body = trimmed.hasPrefix("-") ? String(trimmed.dropFirst()) : trimmed
        if body.contains("-") || body.lowercased().contains(" to ") { return nil }

        // Keep digits, one decimal point and a leading sign; drop units and stray characters.
        var digits = ""
        var seenDot = false
        for (i, ch) in trimmed.enumerated() {
            if ch.isNumber { digits.append(ch) }
            else if ch == "." && !seenDot { seenDot = true; digits.append(ch) }
            else if ch == "-" && i == 0 { digits.append(ch) }
            else if ch == "," { continue }                  // thousands separator
            else if !digits.isEmpty { break }               // number ended; the rest is a unit
        }
        guard !digits.isEmpty, digits != "-", digits != "." else { return nil }
        return Double(digits)
    }

    /// Extract the first balanced `{…}` object from arbitrary text. Brace-counting rather than a regex
    /// so a nested object parses, and quote/escape aware so a brace INSIDE a string value
    /// (`"label": "rice {big}"`) doesn't end the object early. Returns nil when no balanced object is
    /// present — an unterminated one is truncated output, not JSON worth guessing at.
    static func firstJSONObject(in text: String) -> String? {
        let chars = Array(text)
        guard let start = chars.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        for i in start..<chars.count {
            let ch = chars[i]
            if escaped { escaped = false; continue }
            if inString {
                if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(chars[start...i]) }
            default: break
            }
        }
        return nil
    }
}
