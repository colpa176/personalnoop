import XCTest
@testable import StrandImport

/// The parser's job is to turn an untrusted model reply into either a usable estimate or a clean nil.
/// These tests mostly document the ways a reply goes wrong — fences, prose, string numbers, ranges,
/// nonsense magnitudes — and pin that each one degrades to "no estimate" rather than to a wrong number
/// shown as a real one.
final class FoodTextEstimateTests: XCTestCase {

    // MARK: - the happy path

    func testParsesPlainJSONObject() {
        let reply = #"{"label":"Chicken and rice","kcal":620,"protein_g":52,"carbs_g":68,"fat_g":9}"#
        let e = FoodTextEstimator.parse(reply)
        XCTAssertEqual(e?.label, "Chicken and rice")
        XCTAssertEqual(e?.kcal, 620)
        XCTAssertEqual(e?.proteinG, 52)
        XCTAssertEqual(e?.carbsG, 68)
        XCTAssertEqual(e?.fatG, 9)
    }

    func testParsesDecimalValues() {
        let e = FoodTextEstimator.parse(#"{"kcal":412.5,"fat_g":9.25}"#)
        XCTAssertEqual(e?.kcal, 412.5)
        XCTAssertEqual(e?.fatG, 9.25)
    }

    // MARK: - the shapes models actually send

    func testParsesInsideACodeFence() {
        let reply = """
        Here's my estimate:

        ```json
        {"kcal": 450, "protein_g": 30, "carbs_g": 40, "fat_g": 12}
        ```

        Hope that helps!
        """
        let e = FoodTextEstimator.parse(reply)
        XCTAssertEqual(e?.kcal, 450)
        XCTAssertEqual(e?.proteinG, 30)
    }

    func testParsesWithProseOnBothSides() {
        let reply = "Sure — roughly: {\"kcal\": 300, \"protein_g\": 10} — but portion size matters."
        XCTAssertEqual(FoodTextEstimator.parse(reply)?.kcal, 300)
    }

    func testAcceptsKeyAliases() {
        let e = FoodTextEstimator.parse(#"{"calories":500,"protein":20,"carbohydrates":50,"fat":15}"#)
        XCTAssertEqual(e?.kcal, 500)
        XCTAssertEqual(e?.proteinG, 20)
        XCTAssertEqual(e?.carbsG, 50)
        XCTAssertEqual(e?.fatG, 15)
    }

    func testKeyLookupIsCaseAndSeparatorInsensitive() {
        let e = FoodTextEstimator.parse(#"{"Calories": 210, "Protein (g)": 8}"#)
        XCTAssertEqual(e?.kcal, 210)
        XCTAssertEqual(e?.proteinG, 8)
    }

    func testAcceptsNumbersSentAsStrings() {
        let e = FoodTextEstimator.parse(#"{"kcal":"620","protein_g":"52 g","carbs_g":"1,200"}"#)
        XCTAssertEqual(e?.kcal, 620)
        XCTAssertEqual(e?.proteinG, 52)
        XCTAssertEqual(e?.carbsG, 1200, "a thousands separator is a formatting choice, not a parse failure")
    }

    func testIgnoresUnknownExtraKeys() {
        let e = FoodTextEstimator.parse(#"{"kcal":100,"fiber_g":4,"confidence":"high","notes":"a guess"}"#)
        XCTAssertEqual(e?.kcal, 100)
        XCTAssertNil(e?.proteinG)
    }

    func testHandlesNestedObjectsAndBracesInsideStrings() {
        // A brace inside a string value must not end the object early.
        let e = FoodTextEstimator.parse(#"{"label":"rice {large}","kcal":700,"per":{"unit":"bowl"}}"#)
        XCTAssertEqual(e?.label, "rice {large}")
        XCTAssertEqual(e?.kcal, 700)
    }

    // MARK: - absence stays absence

    /// The single most important behaviour: an omitted macro must come back nil, NOT 0. A fabricated 0
    /// would be summed into the day's totals as a real claim.
    func testOmittedMacrosStayNilRatherThanZero() {
        let e = FoodTextEstimator.parse(#"{"kcal":250}"#)
        XCTAssertEqual(e?.kcal, 250)
        XCTAssertNil(e?.proteinG)
        XCTAssertNil(e?.carbsG)
        XCTAssertNil(e?.fatG)
    }

    /// An explicit zero the model DID assert is kept — "logged, zero fat" is a real statement, and it is
    /// the omission case above that must stay distinguishable from it.
    func testExplicitZeroIsKept() {
        let e = FoodTextEstimator.parse(#"{"kcal":90,"fat_g":0}"#)
        XCTAssertEqual(e?.fatG, 0)
    }

    func testExplicitNullIsTreatedAsAbsent() {
        let e = FoodTextEstimator.parse(#"{"kcal":90,"protein_g":null}"#)
        XCTAssertEqual(e?.kcal, 90)
        XCTAssertNil(e?.proteinG)
    }

    // MARK: - refusals (each of these must fall back to the manual form)

    func testEmptyObjectIsNoEstimate() {
        XCTAssertNil(FoodTextEstimator.parse("{}"), "the prompt's answer for 'not food'")
    }

    func testProseWithNoJSONIsNoEstimate() {
        XCTAssertNil(FoodTextEstimator.parse("I can't estimate that without knowing the portion size."))
    }

    func testEmptyReplyIsNoEstimate() {
        XCTAssertNil(FoodTextEstimator.parse(""))
        XCTAssertNil(FoodTextEstimator.parse("   \n  "))
    }

    func testTruncatedJSONIsNoEstimate() {
        XCTAssertNil(FoodTextEstimator.parse(#"{"kcal": 620, "protein_g":"#),
                     "an unbalanced object is truncated output, not something to guess at")
    }

    func testLabelOnlyIsNoEstimate() {
        XCTAssertNil(FoodTextEstimator.parse(#"{"label":"chicken and rice"}"#),
                     "a name with no numbers is not an estimate")
    }

    func testRangesAreRefusedRatherThanHalved() {
        let e = FoodTextEstimator.parse(#"{"kcal":"400-600","protein_g":30}"#)
        XCTAssertNil(e?.kcal, "picking an end of a range would be inventing precision")
        XCTAssertEqual(e?.proteinG, 30, "one bad field must not discard the good ones")
    }

    func testBooleanIsNotAQuantity() {
        let e = FoodTextEstimator.parse(#"{"kcal":true,"protein_g":12}"#)
        XCTAssertNil(e?.kcal)
        XCTAssertEqual(e?.proteinG, 12)
    }

    // MARK: - plausibility bounds

    func testAbsurdEnergyIsDroppedNotClamped() {
        let e = FoodTextEstimator.parse(#"{"kcal":250000,"protein_g":40}"#)
        XCTAssertNil(e?.kcal, "clamping would still be a fabricated number, just a less obvious one")
        XCTAssertEqual(e?.proteinG, 40)
    }

    func testAbsurdMacroIsDropped() {
        let e = FoodTextEstimator.parse(#"{"kcal":500,"protein_g":99999}"#)
        XCTAssertEqual(e?.kcal, 500)
        XCTAssertNil(e?.proteinG)
    }

    func testNegativeValuesAreDropped() {
        let e = FoodTextEstimator.parse(#"{"kcal":-200,"fat_g":10}"#)
        XCTAssertNil(e?.kcal)
        XCTAssertEqual(e?.fatG, 10)
    }

    func testAValueExactlyOnTheBoundIsAccepted() {
        let e = FoodTextEstimator.parse(#"{"kcal":10000}"#)
        XCTAssertEqual(e?.kcal, FoodTextEstimator.maxKcal)
    }

    // MARK: - prompt

    func testPromptCarriesTheUserTextAndTheOmitRule() {
        let p = FoodTextEstimator.prompt(for: "chicken breast and rice for lunch")
        XCTAssertTrue(p.contains("chicken breast and rice for lunch"))
        XCTAssertTrue(p.contains("protein_g"))
        XCTAssertTrue(p.contains("OMIT"), "the omit-don't-guess instruction is what keeps unknown ≠ zero")
    }

    // MARK: - helpers

    func testFirstJSONObjectStopsAtTheBalancedBrace() {
        let text = "before {\"a\":1} after {\"b\":2}"
        XCTAssertEqual(FoodTextEstimator.firstJSONObject(in: text), "{\"a\":1}")
    }

    func testNormalizeKeyStripsSeparatorsAndCase() {
        XCTAssertEqual(FoodTextEstimator.normalizeKey("Protein (g)"), "proteing")
        XCTAssertEqual(FoodTextEstimator.normalizeKey("protein_g"), "proteing")
        XCTAssertEqual(FoodTextEstimator.normalizeKey("proteinG"), "proteing")
    }

    func testCoerceNumberHandlesUnitsAndJunk() {
        XCTAssertEqual(FoodTextEstimator.coerceNumber("620 kcal"), 620)
        XCTAssertEqual(FoodTextEstimator.coerceNumber("~35g"), 35)
        XCTAssertEqual(FoodTextEstimator.coerceNumber("12.5"), 12.5)
        XCTAssertNil(FoodTextEstimator.coerceNumber("about a plateful"))
        XCTAssertNil(FoodTextEstimator.coerceNumber(""))
    }
}
