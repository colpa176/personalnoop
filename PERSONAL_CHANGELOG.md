# personalnoop changelog

What this fork (`colpa176/personalnoop`) adds on top of upstream [`ryanbr/noop`](https://github.com/ryanbr/noop).
Upstream's own history is in [CHANGELOG.md](CHANGELOG.md) and [docs/releases/](docs/releases/); this file
only tracks the personal changes and each upstream sync.

## 2026-10-12: Synced with upstream 12.1.0

Merged 1,594 upstream commits (9.2.3 → 12.1.0). Every personal feature below was kept, except where
upstream shipped the same thing itself.

**Fixed: SideStore install** ("Invalid parameters, could not locate signing certificate")
- The fork's 9.2.x iOS builds were completely unsigned. SideStore reads an app's existing signature to
  find its entitlements (HealthKit, the app group shared with the widget) before re-signing it. With no
  signature it fails. Upstream's release workflow now adds an ad-hoc signature with those entitlements
  (`Tools/prepare-ios-sideload-app.sh`), and this sync brings that in.
- `altstore-source.json` now uses upstream's layout, including the `appPermissions` block SideStore reads,
  and still points at this fork. The old unsigned 9.2.x entries were removed; the release workflow adds
  each new version.

**Changed by the sync**
- **AI Coach conversation history:** replaced by upstream's version. Upstream built its own saved Coach
  conversation (`v43-coach-messages`, with Android support and a daily reset of yesterday's chat), so the
  fork's `v32-coach-conversation` table, `CoachConversationStore`, and the Settings → Coach "Clear
  conversation history" panel were removed. Use the Coach screen's own Clear action. An existing
  `coachTurn` table on a device that ran the old fork build is left in place and no longer read.
- **Nutrition:** now listed under **More → Body → Nutrition**. Upstream switched to the native iPhone tab
  bar, which fits five tabs, and made Coach the fourth (Today / Trends / Sleep / Coach / More).
- **Asleep-duration trend:** still drawn as a dot/line chart. Upstream moved that card into
  `AsleepDurationCard.swift`, so the change was re-applied there.
- **Food-log database migration:** `v33-food-log` now runs after all upstream migrations, under its
  original name, so a database that already has the table skips it.
- **Translations:** added Polish for all fork strings (upstream added Polish), and translated nine food-log
  status messages that had been English-only.
- **CI:** kept the fork's "build every branch" push trigger on `app-build.yml` and `swift-packages.yml`.
  Upstream removed it to save macOS runner minutes. The release workflow's version-bump commit now uses the
  fork's noreply identity, like the AltStore commit already did.
- **Branch pruning:** upstream's new `prune-stale-branches.yml` runs here only when started manually, not
  on its weekly schedule, so it can't delete this fork's feature branches on its own.

## Personal features (9.2.x)

- **Nutrition:** food and hydration logging with daily-total trends. You can type what you ate and have
  the AI provider you connected in Coach estimate calories and macros, or enter the numbers yourself. Only
  the text you type is sent; nothing is sent without a provider. A macro you leave blank is stored as
  unknown, not zero. Daily totals feed Explore and Compare, and the Coach gets them as per-day summaries
  (never the meal text).
- **Manual weight entry** on the Weight detail page. It is stored on the device and takes priority over
  Apple Health for that day.
- **Screen time import** through a `noop://import-screentime` link, so a Shortcut can log daily screen
  time. It asks for confirmation first.
- **Custom self-experiments:** free-text experiment names, a window you can extend (+5 / +10 days), and
  an optional written summary of the result from your AI provider.
- **Today's journal card** links straight to "What Moves You".
- **Logged-total trends** (hydration, nutrition) drawn as dot/line charts instead of bars.
- **Honest empty states** for Weight, Steps (est) and SpO2. They no longer tell you to import a WHOOP
  export that can't fill them.
- **Tooling fixes:** the doc-comment and i18n audit baselines work on any platform's path separators.
