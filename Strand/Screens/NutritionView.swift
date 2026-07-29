import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Nutrition — the dedicated food + hydration logging home (the iPhone tab bar's fifth tab).
///
/// Deliberately a LOGGING surface, not an analysis one. It shows what you logged and how the daily
/// totals trend, and nothing else: no correlation against sleep or recovery, no insights, no
/// recommendations. Every interpretation of this data stays in the AI Coach chat, which can read the
/// same rows (`AICoachEngine.nutritionBlock()`) and be asked about them there. Keeping the two apart
/// is the point — a logging page that also editorialises stops being a place you trust to just record
/// what you ate.
///
/// It composes surfaces that already exist rather than reimplementing them:
///   • `FoodLogCard` is the whole food path (quick-add box, optional Coach macro estimate, manual
///     fallback, running list). Here it runs `newestFirst` so the entry just saved sits on top, the
///     quick-add convention MyFitnessPal / Cronometer / MacroFactor share.
///   • Hydration reuses `Repository.logHydration` + the existing Sip/Cup/Bottle amounts, so the water
///     logged here is the same data the Hydration screen and Today card already show. The full screen
///     (history, editing, custom container sizes) stays one tap away rather than being duplicated.
///   • The trends use the app's `TrendChart`, so nothing new is introduced to the chart layer.
struct NutritionView: View {
    @EnvironmentObject private var repo: Repository

    /// The local day being logged against, re-resolved on appear so a rollover with the app alive
    /// doesn't keep logging into yesterday (the same guard `FoodLogCard` applies).
    @State private var dayKey = Repository.foodLogDayKey()
    @State private var hydrationML: Double = 0
    /// Daily food totals over the trend window, oldest day first.
    @State private var foodHistory: [FoodDayTotals] = []
    /// Daily hydration totals over the same window.
    @State private var hydrationHistory: [(day: String, value: Double)] = []
    @State private var loaded = false

    /// Trend window. 30 days matches the "Last 30 days" range the rest of the app offers and is long
    /// enough for a weekly rhythm to be visible without the bars collapsing into hairlines.
    private static let trendDays = 30

    var body: some View {
        ScreenScaffold(title: "Nutrition",
                       subtitle: "Log what you eat and drink, and see how it trends.",
                       onRefresh: { await load() },
                       topBackground: liquidScaffoldSky()) {
            // Food: quick-add + today's running totals + the day's entries, newest first.
            FoodLogCard(newestFirst: true)

            hydrationSection
            trendsSection
        }
        // Keyed on the refresh seq, the day, and the hydration counter so the page reloads on any write —
        // hydration writes don't bump `refreshSeq`, which is why `hydrationSeq` exists (#989).
        .task(id: NutritionLoadKey(seq: repo.refreshSeq,
                                   day: dayKey,
                                   hydration: repo.hydrationSeq)) { await load() }
        .onAppear { dayKey = Repository.foodLogDayKey() }
    }

    /// Composite reload key — see the `.task(id:)` note above.
    private struct NutritionLoadKey: Equatable {
        let seq: Int
        let day: String
        let hydration: Int
    }

    // MARK: - Hydration

    /// Compact water quick-add. The amounts and their labels are the SAME constants and strings the
    /// Hydration screen uses, so a glass logged here is indistinguishable from one logged there.
    private var hydrationSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Hydration", overline: "Log")
            NoopCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(hydrationML > 0 ? "\(Int(hydrationML.rounded()))" : "—")
                            .font(StrandFont.title2)
                            .foregroundStyle(hydrationML > 0 ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                        Text("ml")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Spacer(minLength: 8)
                        Text("Hydration today")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }

                    HStack(spacing: NoopMetrics.gap) {
                        logButton("Sip", systemImage: "drop", ml: HydrationGoal.sipML)
                        logButton("Cup", systemImage: "cup.and.saucer.fill", ml: HydrationGoal.cupML)
                        logButton("Bottle", systemImage: "drop.fill", ml: HydrationGoal.bottleML)
                    }

                    // Editing, deleting, custom container sizes and the 7-day bars all live on the
                    // Hydration screen already — link to it instead of growing a second copy here.
                    NavigationLink(value: TabRoute.hydration) {
                        HStack(spacing: 4) {
                            Text("Hydration")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.accent)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(StrandPalette.accent)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// One quick-add button, matching the Hydration screen's secondary style and accessibility label.
    private func logButton(_ title: LocalizedStringKey, systemImage: String, ml: Int) -> some View {
        NoopButton(title, systemImage: systemImage, kind: .secondary, fullWidth: true) {
            Task {
                hydrationML = await repo.logHydration(amountMl: ml, day: dayKey)
                await loadTrends()
            }
        }
        .accessibilityLabel("Log \(title)")
    }

    // MARK: - Trends

    /// Daily totals over the window. Purely "what did I log" — the graphs carry no interpretation and
    /// are never compared against recovery or sleep here (that belongs to Coach).
    @ViewBuilder private var trendsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Trends", overline: "Nutrition", trailing: String(localized: "Last 30 days"))

            if !loaded {
                // Nothing to say yet; the scaffold's own load state covers the gap.
                EmptyView()
            } else if caloriePoints.isEmpty && hydrationPoints.isEmpty && macroSeries.isEmpty {
                NoopCard {
                    Text("No history yet.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            } else {
                if !caloriePoints.isEmpty {
                    chart("Calories", points: caloriePoints, gradient: StrandPalette.effortGradient)
                }
                // One card per macro that actually has data, so the rhythm of each is readable and a
                // macro nobody logs never occupies space with an empty frame.
                ForEach(macroSeries, id: \.id) { series in
                    chart(series.title, points: series.points, gradient: series.gradient,
                          height: NoopMetrics.chartHeight * 0.7)
                }
                if !hydrationPoints.isEmpty {
                    chart("Hydration", points: hydrationPoints, gradient: StrandPalette.restGradient)
                }
            }
        }
    }

    /// One trend card. Bars (not a line) because these are DAILY TOTALS — a discrete amount per day,
    /// with legitimate gaps on days nothing was logged; a continuous line would imply the gaps were
    /// interpolated values.
    private func chart(_ title: LocalizedStringKey, points pts: [TrendPoint], gradient: Gradient,
                       height: CGFloat = NoopMetrics.chartHeight) -> some View {
        ChartCard(title: title, height: height) {
            TrendChart(points: pts,
                       gradient: gradient,
                       valueRange: 0...max(1, pts.map(\.value).max() ?? 1),
                       showsBars: true,
                       height: height)
        }
    }

    /// One macro's series, built only when at least one day actually recorded that macro — a macro
    /// nobody logged gets no chart rather than a flat zero line.
    private struct MacroSeries: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let points: [TrendPoint]
        let gradient: Gradient
    }

    private var macroSeries: [MacroSeries] {
        [
            MacroSeries(id: "protein", title: "Protein",
                        points: points(\.proteinG), gradient: StrandPalette.recoveryGradient),
            MacroSeries(id: "carbs", title: "Carbs",
                        points: points(\.carbsG), gradient: StrandPalette.strainGradient),
            MacroSeries(id: "fat", title: "Fat",
                        points: points(\.fatG), gradient: StrandPalette.chargeGradient),
        ].filter { !$0.points.isEmpty }
    }

    private var caloriePoints: [TrendPoint] { points(\.kcal) }

    /// Map the day totals onto chart points for one macro. A day whose total for that macro is absent
    /// is SKIPPED, not plotted as 0 — the store keeps "nothing logged" distinct from "logged zero" all
    /// the way down to the nullable column, and the chart must not undo that.
    private func points(_ macro: KeyPath<FoodDayTotals, Double?>) -> [TrendPoint] {
        foodHistory.compactMap { total in
            guard let value = total[keyPath: macro],
                  let date = Repository.localDay(fromKey: total.day) else { return nil }
            return TrendPoint(date: date, value: value)
        }
    }

    private var hydrationPoints: [TrendPoint] {
        hydrationHistory.compactMap { row in
            guard row.value > 0, let date = Repository.localDay(fromKey: row.day) else { return nil }
            return TrendPoint(date: date, value: row.value)
        }
    }

    // MARK: - Load

    private func load() async {
        hydrationML = await repo.hydrationTotal(day: dayKey)
        await loadTrends()
        loaded = true
    }

    private func loadTrends() async {
        let days = Repository.recentDayKeys(Self.trendDays)
        guard let first = days.first, let last = days.last else { return }
        foodHistory = await repo.foodTotals(from: first, to: last)
        hydrationHistory = await repo.hydrationHistory(days: Self.trendDays)
    }
}
