# F01 — Design system and interaction patterns

**Depends on:** F00.

**Build**

- Implement semantic tokens for background, sidebar, surface, raised surface, primary/secondary text, border, accent, success, and warning. Use color roles instead of hex values in feature views.
- Use the selected Black / Red Terminal direction. Keep legible text contrast, clear keyboard focus, reduced-motion behavior, and native controls where they improve accessibility.
- Use short labels and useful metadata. Remove explanatory subtitles, slogans, and repeated helper text from normal screens; show guidance only for empty states, errors, or decisions that need it. Add small, consistent outline icons beside navigation labels and common actions. Keep visible text labels for navigation and accessible labels for icon-only controls.
- Reusable components: page header, section header, next-action card, list row, status pill, empty state, confirmation/undo affordance, and loading/error states.
- Set top navigation in the approved order: Today, Learning, Projects, Focus, Tasks, News, Settings. Keep topic navigation inside Learning and folder navigation inside Projects.

**Done when:** destinations compile with shared components and appropriate empty/seeded states; source review confirms layout and control wiring.

## Function → mockup contract

| Function / page | Dedicated visual | Expected behavior |
| --- | --- | --- |
| Typography, colors and icons | [M42 · Appearance](../mockups/M42-design-accessibility.png) | Apply shared tokens; status is communicated by text and icon as well as color. |
| Navigation, keyboard and focus | [M00 · Today](../mockups/M00-app-shell.png) | Icons retain visible labels; keyboard focus follows visual order. |

## Implementation checklist

- [ ] Implement AppColors, AppTypography, IconLabel, PageHeader, ActionButton, EmptyState and ErrorBanner.
- [ ] Use SF Symbols with house, book, folder, timer, checkmark.square, newspaper and gearshape roles; check symbol availability at the deployment target.
- [ ] Use 4–8 point corner radii, mostly unframed rows, and minimal copy; no slogans or data-storage explanations in normal pages.
- [ ] Keep touch-sized targets where practical and at least 32-point desktop click targets; label standalone icon controls for VoiceOver.
- [ ] Preserve adaptive layout and reflow implementation; compile it without opening windows.

## Non-interactive acceptance checks

Follow [AGENTS.md](../../AGENTS.md). Accessibility, keyboard/focus, live layout and hosted UI checks are removed, not deferred; preserve their product implementations.

- [ ] Shared components and destination views compile.
- [ ] Source uses shared tokens and existing control/state ownership.
- [ ] Build and static analysis pass.

## Visual references

![M42 · Appearance](../mockups/M42-design-accessibility.png)

![M00 · Today](../mockups/M00-app-shell.png)

[Back to PLAN](../../PLAN.md) · [All screens](../mockups/INDEX.md) · [Data contracts](../architecture.md)
