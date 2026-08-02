import SwiftUI
import StrandDesign

// MARK: - Manual weight entry sheet
//
// The escape hatch for the one Explore metric the strap can never measure. The Weight detail page
// explains that body mass comes from Apple Health because the band has no scale; this is the "and if
// you don't have Apple Health, type it" half of that sentence.
//
// A free TextField rather than the Stepper the hydration sheet uses: weight spans 30-250 kg at 0.1
// resolution, so stepping to a value would take hundreds of taps. Entry is in the user's OWN unit
// (kg or lb, from the single `UnitPrefs.systemKey` toggle) and converted to the canonical kilograms
// at the boundary, so nothing downstream has to know which system was on screen.
//
// Save stays disabled until the text parses to a plausible mass, so the sheet cannot write a value
// `ManualWeightStore` would silently reject — the button state is the validation feedback.
struct ManualWeightSheet: View {
    /// Pre-fills the field when correcting a day that already has a value (kilograms), nil for a
    /// fresh entry.
    let initialKg: Double?
    let onSave: (Double) -> Void
    let onCancel: () -> Void

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    @State private var text: String = ""
    /// One field, but an OPTIONAL-valued FocusState: `keyboardDoneToolbar` takes a
    /// `FocusState<Value?>.Binding` so it can resign focus by writing nil, the same shape
    /// `ManualWorkoutSheet` and `MarkerEditorView` use.
    private enum Field: Hashable { case weight }
    @FocusState private var focused: Field?

    init(initialKg: Double?, onSave: @escaping (Double) -> Void, onCancel: @escaping () -> Void) {
        self.initialKg = initialKg
        self.onSave = onSave
        self.onCancel = onCancel
    }

    /// The typed text as kilograms, or nil when it doesn't parse or isn't a plausible mass.
    ///
    /// Accepts a comma decimal separator: the iOS decimal pad emits whatever the device locale uses,
    /// so a German or French keyboard types "74,5" and `Double("74,5")` is nil. Normalising here
    /// keeps those users from a field that silently refuses every value they enter.
    private var parsedKg: Double? {
        let normalised = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let entered = Double(normalised), entered.isFinite else { return nil }
        let kg = unitSystem == .imperial ? UnitFormatter.poundsToKg(entered) : entered
        return ManualWeightStore.plausibleKg.contains(kg) ? kg : nil
    }

    /// The plausible range restated in whatever unit is on screen, so the hint matches the field.
    private var rangeHint: String {
        let lo = ManualWeightStore.plausibleKg.lowerBound
        let hi = ManualWeightStore.plausibleKg.upperBound
        return "\(UnitFormatter.massFromKilograms(lo, system: unitSystem)) – \(UnitFormatter.massFromKilograms(hi, system: unitSystem))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            Text("Manual override")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)

            Text("Type today's weight. It's stored on this \(Platform.deviceNoun) only, and it takes priority over Apple Health for the day you enter.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("0", text: $text)
                    .textFieldStyle(.plain)
                    .font(StrandFont.rounded(34, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                    .numericKeyboard()
                    .focused($focused, equals: .weight)
                    // Whole-string keys per unit, not "Weight in " + a raw "kg"/"lb" tail: a stitched
                    // fragment leaves the unit untranslated inside a translated sentence, and both
                    // variants are already in the catalog.
                    .accessibilityLabel(unitSystem == .imperial
                                        ? Text("Weight in pounds") : Text("Weight in kilograms"))
                Text(UnitFormatter.massUnit(unitSystem))
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused == .weight ? StrandPalette.focusRing : StrandPalette.hairline, lineWidth: 1))

            Text("Enter a value between \(rangeHint).")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)

            HStack(spacing: NoopMetrics.gap) {
                NoopButton("Cancel", kind: .secondary, fullWidth: true) { onCancel() }
                NoopButton("Save", kind: .primary, fullWidth: true) {
                    if let kg = parsedKg { onSave(kg) }
                }
                .disabled(parsedKg == nil)
            }
        }
        .padding(NoopMetrics.space5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .keyboardDoneToolbar($focused)
        .onAppear {
            // Pre-fill in the unit on screen, trimmed to one decimal — the same precision the field
            // asks for, so re-saving an untouched value is a no-op rather than a rounding nudge.
            if let kg = initialKg {
                let shown = unitSystem == .imperial ? UnitFormatter.kgToPounds(kg) : kg
                text = String(format: "%.1f", shown)
            }
            focused = .weight
        }
        // iOS-only sheet sizing — macOS sheets are free-floating windows and reject detents (same
        // note as HydrationAmountSheet); the call site stays cross-platform via this guard.
        #if os(iOS)
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.visible)
        #endif
    }
}
