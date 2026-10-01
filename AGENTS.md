# Repository instructions

## Validation policy

- Use non-interactive validation only: source review, builds, `build-for-testing`, static analysis, resource/schema/link checks, and explicitly selected non-GUI unit, persistence, and integration tests.
- Do not require or run accessibility/AX/VoiceOver checks, native keyboard/focus checks, hosted UI/presentation tests, screenshot comparisons, or manual/live-app journeys. Do not launch or operate the app, press buttons, send synthetic input, open native dialogs, or request desktop/Accessibility authorization for validation.
- These checks are removed from task, review, and release gates, not deferred to F13 or another task. Missing GUI permission or interactive evidence is not a blocker.
- Do not run unfiltered `make test` or `xcodebuild test`: existing suites include GUI interaction. Inspect tests and select non-GUI suites or methods explicitly. A test runner process for isolated domain tests is allowed; driving the running application is not.
- Preserve product behavior, including accessibility and keyboard support. This policy removes validation requirements, not features or test assertions.
- Preserve historical failures, skips, and logs as evidence, not current instructions. Do not relabel excluded or unexecuted checks as passing. Record actual commands and results; non-GUI failures still need investigation.
- Keep production data untouched; use isolated fixtures. Retain non-interactive signing, entitlement, packaging, checksum, and notarization requirements for distribution.
- This policy governs all plans, task checklists, and documentation, including archived `.pi/workflows` plans. Do not reinstate obsolete GUI gates from historical reports.
