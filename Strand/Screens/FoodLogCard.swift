import SwiftUI
import StrandDesign
import WhoopStore
import StrandImport

/// Food log — type what you ate, optionally have the configured Coach model estimate the macros, then
/// save it. Manual-first and honest by construction:
///
///   • Logging NEVER depends on an API key. With no Coach connected the Estimate control simply isn't
///     offered and the same form is filled in by hand; with one connected, an estimate PRE-FILLS the
///     form and the user still presses Save. A model's guess is never written behind their back.
///   • An unknown value stays unknown. A blank field is stored as absent, not as 0, all the way down to
///     the nullable column — the same rule the caffeine log follows for an unknown dose.
///   • An estimated entry is labelled as estimated, and stops being labelled that the moment the user
///     edits the numbers.
///
/// Totals for the day roll up into the SAME metric-series keys the nutrition CSV importer writes
/// (see `Repository.saveFoodEntry`), so a logged meal reaches Explore/Compare/Insights through the path
/// imported nutrition already uses.
struct FoodLogCard: View {
    /// Order the "Logged today" list newest-first instead of oldest-first. The Nutrition tab is a
    /// running log the user adds to through the day, where the entry just saved should be at the top
    /// (the quick-add convention MyFitnessPal / Cronometer / MacroFactor all follow); the Health hub
    /// reads as a chronological day and keeps the oldest-first default, so neither host changes the
    /// other. Display-only — `entries` is always stored and summed in time order.
    var newestFirst: Bool = false

    /// Explicit, so the card stays constructible from another file. The card holds `@State private`
    /// properties, which drags the access level of a SYNTHESISED memberwise init down with them — the
    /// existing `FoodLogCard()` calls only kept working because that's the zero-argument DEFAULT init,
    /// which is unaffected. Adding a parameter would otherwise have been callable only from this file.
    init(newestFirst: Bool = false) {
        self.newestFirst = newestFirst
    }

    @EnvironmentObject var repo: Repository
    @EnvironmentObject var model: AppModel

    /// The local day being logged against. Re-resolved when the view appears so a day that rolls over
    /// with the app alive doesn't keep logging into yesterday.
    @State private var dayKey = Repository.foodLogDayKey()
    @State private var entries: [FoodLogEntry] = []
    @State private var totals: FoodDayTotals?

    /// What the user typed.
    @State private var draft = ""
    /// The macro fields. Strings, so blank stays blank — a `Double` field with a 0 default would quietly
    /// turn "I don't know" into a claim of zero.
    @State private var kcalDraft = ""
    @State private var proteinDraft = ""
    @State private var carbsDraft = ""
    @State private var fatDraft = ""

    @State private var estimating = false
    @State private var saving = false
    @State private var statusText: String?
    @State private var statusIsError = false

    /// The numbers the last accepted estimate filled in. Kept so an entry is only marked "estimated"
    /// while it still holds the model's values — editing any of them makes it the user's own number.
    @State private var estimateFilled: [String]?

    @FocusState private var textFocused: Bool

    private var coach: AICoachEngine { model.coach }
    private var canEstimate: Bool { coach.isConfigured }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Food", overline: "Log", trailing: entries.isEmpty ? nil : entryCountLabel)
            NoopCard(tint: StrandPalette.accent) {
                VStack(alignment: .leading, spacing: 10) {
                    totalsRow
                    Divider().overlay(StrandPalette.hairline)
                    composer
                    macroFields
                    actions
                    if let statusText {
                        statusLine(statusText)
                    }
                    if !entries.isEmpty {
                        Divider().overlay(StrandPalette.hairline)
                        loggedList
                    }
                    footnote
                }
            }
        }
        // Keyed on BOTH the data-refresh seq and the day, so the card reloads on a write and again the
        // moment the calendar day rolls over with the app alive — otherwise yesterday's entries would
        // stay pinned under "Logged today" (the same trap InsightsView's day-key task guards against).
        .task(id: FoodLogLoadKey(seq: repo.refreshSeq, day: dayKey)) { await load() }
        .onAppear { dayKey = Repository.foodLogDayKey() }
    }

    /// Composite reload key — see the `.task(id:)` note above.
    private struct FoodLogLoadKey: Equatable {
        let seq: Int
        let day: String
    }

    private var entryCountLabel: String {
        entries.count == 1 ? String(localized: "1 entry") : String(localized: "\(entries.count) entries")
    }

    // MARK: - Today's totals

    /// The running totals. A macro nothing recorded reads "—", never 0 — the card must not report a
    /// number the log doesn't contain.
    private var totalsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(totals?.kcal.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(StrandFont.title2)
                    .foregroundStyle(totals?.kcal == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                Text("kcal today")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            HStack(spacing: 14) {
                macroTotal("Protein", grams: totals?.proteinG)
                macroTotal("Carbs", grams: totals?.carbsG)
                macroTotal("Fat", grams: totals?.fatG)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func macroTotal(_ label: LocalizedStringKey, grams: Double?) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(grams.map { "\(Int($0.rounded()))g" } ?? "—")
                .font(StrandFont.captionNumber)
                .foregroundStyle(grams == nil ? StrandPalette.textTertiary : StrandPalette.textSecondary)
        }
    }

    // MARK: - Entry

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("What did you eat? e.g. chicken breast and rice", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1...3)
                .focused($textFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(textFocused ? StrandPalette.focusRing : StrandPalette.hairline, lineWidth: 1))
                .accessibilityLabel("What did you eat")
        }
    }

    /// Calories + macros. Always visible, whether or not an estimate filled them: this is the one form
    /// both paths land in, so there is no separate "manual mode" to fall into and no state where the
    /// user can't see the numbers about to be saved.
    private var macroFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                macroField("Calories", text: $kcalDraft, unit: "kcal")
                macroField("Protein", text: $proteinDraft, unit: "g")
            }
            HStack(spacing: 8) {
                macroField("Carbs", text: $carbsDraft, unit: "g")
                macroField("Fat", text: $fatDraft, unit: "g")
            }
            Text("Leave any field blank if you don't know it — blank is stored as unknown, not as zero.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func macroField(_ label: LocalizedStringKey, text: Binding<String>, unit: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            HStack(spacing: 4) {
                // Placeholder is a dash, not "0": an empty field means unknown, and priming it with a
                // zero would invite exactly the claim this card is careful never to make.
                TextField("—", text: text)
                    .textFieldStyle(.roundedBorder)
                #if os(iOS)
                    .keyboardType(.decimalPad)
                #endif
                    .accessibilityLabel(Text(label))
                Text(unit)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if canEstimate {
                Button(action: runEstimate) {
                    HStack(spacing: 6) {
                        if estimating {
                            ProgressView().controlSize(.small).tint(StrandPalette.accent)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text("Estimate")
                    }
                }
                .buttonStyle(NoopButtonStyle(.secondary))
                .disabled(estimating || saving || trimmedDraft.isEmpty)
                .accessibilityLabel("Estimate calories and macros from the text")
            }

            NoopButton("Save", systemImage: "plus", kind: .primary, action: save)
                .disabled(saving || estimating || trimmedDraft.isEmpty)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func statusLine(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "sparkles")
                .font(StrandFont.footnote)
                .foregroundStyle(statusIsError ? StrandPalette.statusWarning : StrandPalette.accent)
                .accessibilityHidden(true)
            Text(message)
                .font(StrandFont.footnote)
                .foregroundStyle(statusIsError ? StrandPalette.statusWarning : StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Logged list

    @ViewBuilder private var loggedList: some View {
        Text("Logged today")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
        // `Array(...)` on both arms deliberately: `entries.reversed()` is a `ReversedCollection`, which
        // will not unify with `[FoodLogEntry]` across a ternary.
        ForEach(newestFirst ? Array(entries.reversed()) : entries) { entry in
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.text)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detailLine(entry))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 8)
                Button {
                    delete(entry)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.statusCritical)
                }
                .buttonStyle(.plain)
                .disabled(saving)
                .accessibilityLabel("Remove \(entry.text)")
            }
        }
    }

    /// One entry's numbers, plus an explicit "estimated" marker when the numbers came from the model —
    /// the user should never have to remember which rows they typed themselves.
    private func detailLine(_ entry: FoodLogEntry) -> String {
        var parts: [String] = []
        if let k = entry.kcal { parts.append("\(Int(k.rounded())) kcal") }
        if let p = entry.proteinG { parts.append("P \(Int(p.rounded()))g") }
        if let c = entry.carbsG { parts.append("C \(Int(c.rounded()))g") }
        if let f = entry.fatG { parts.append("F \(Int(f.rounded()))g") }
        if parts.isEmpty { parts.append(String(localized: "no numbers logged")) }
        var line = parts.joined(separator: " · ")
        if entry.isEstimated { line += " · " + String(localized: "estimated") }
        return line
    }

    private var footnote: some View {
        Text(canEstimate
             ? "Estimates come from the model you connected in Coach, using only the text you type here — none of your metrics are sent. They're approximations: check them before saving."
             : "Connect a provider in Coach to have calories and macros estimated from what you type. Without one, type the numbers yourself — logging works either way, entirely on \(Platform.deviceNounPhrase).")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func load() async {
        entries = await repo.foodEntries(day: dayKey)
        totals = await repo.foodTotals(day: dayKey)
    }

    /// Ask the configured provider for an estimate and PRE-FILL the fields. Never saves on its own —
    /// the user still presses Save, so a wrong guess is caught before it reaches the log.
    private func runEstimate() {
        let text = trimmedDraft
        guard !text.isEmpty else { return }
        estimating = true
        statusText = nil
        statusIsError = false
        Task {
            let outcome = await FoodLogEstimator.estimate(text: text, coach: coach)
            switch outcome {
            case .estimated(let e):
                apply(e)
                statusText = String(localized: "Estimated by \(coach.provider.displayName). Check the numbers, then save.")
                statusIsError = false
            case .notConfigured:
                statusText = String(localized: "No provider connected. Type the numbers in yourself, or connect one in Coach.")
                statusIsError = true
            case .unusableReply:
                statusText = String(localized: "Couldn't read an estimate from the reply. Type the numbers in yourself, or try rephrasing.")
                statusIsError = true
            case .failed(let message):
                statusText = message
                statusIsError = true
            }
            estimating = false
        }
    }

    /// Fill the fields from an estimate. A value the model omitted leaves its field BLANK rather than
    /// writing 0 — the whole point of the omit-don't-guess prompt.
    private func apply(_ e: FoodTextEstimate) {
        kcalDraft = format(e.kcal)
        proteinDraft = format(e.proteinG)
        carbsDraft = format(e.carbsG)
        fatDraft = format(e.fatG)
        estimateFilled = [kcalDraft, proteinDraft, carbsDraft, fatDraft]
    }

    private func format(_ v: Double?) -> String {
        guard let v else { return "" }
        return v == v.rounded() ? String(Int(v.rounded())) : String(format: "%.1f", v)
    }

    private func save() {
        let text = trimmedDraft
        guard !text.isEmpty, !saving else { return }
        saving = true
        // Still the model's numbers only if none of them has been touched since it filled them in.
        let untouched = estimateFilled == [kcalDraft, proteinDraft, carbsDraft, fatDraft]
        let entry = FoodLogEntry(
            id: UUID().uuidString,
            day: dayKey,
            ts: Int(Date().timeIntervalSince1970),
            text: text,
            kcal: parse(kcalDraft),
            proteinG: parse(proteinDraft),
            carbsG: parse(carbsDraft),
            fatG: parse(fatDraft),
            source: untouched ? .ai : .manual
        )
        Task {
            let ok = await repo.saveFoodEntry(entry)
            if ok {
                resetComposer()
            } else {
                statusText = String(localized: "Couldn't open the local store, so that wasn't saved.")
                statusIsError = true
            }
            await load()
            saving = false
        }
    }

    private func delete(_ entry: FoodLogEntry) {
        saving = true
        Task {
            _ = await repo.deleteFoodEntry(id: entry.id, day: entry.day)
            await load()
            saving = false
        }
    }

    private func resetComposer() {
        draft = ""
        kcalDraft = ""
        proteinDraft = ""
        carbsDraft = ""
        fatDraft = ""
        estimateFilled = nil
        statusText = nil
        statusIsError = false
        textFocused = false
    }

    /// Blank (or unparseable) stays nil — an unknown macro must never become a stored 0. A negative is
    /// rejected the same way rather than clamped, so a typo can't quietly become data.
    private func parse(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, let v = Double(t), v.isFinite, v >= 0 else { return nil }
        return v
    }
}
