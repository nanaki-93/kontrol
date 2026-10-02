# Retired native app evidence

The SwiftUI/SwiftData application was removed on 2026-10-02. Kontrol now consists
of the [web application](../../web-app.md). These records preserve the original
observations, including failures, skips, logs and incomplete release checks.
They do not define current tasks or validation gates. The repository's
[validation policy](../../../AGENTS.md) governs all work, including this archive.

- [Implementation history](implementation-ledger.md): former native README and dated results.
- [QA ledger](qa.md): detailed historical commands, results and artifact paths.
- [UI refinement plan](ui-refinement-plan.md) and [adoption report](ui-adoption-report.md): previous scope, decisions and checks.
- [Legacy export format](export-format.md): schema-version-1 JSON reference for old exports; the current importer is defined by [web schemas](../../../web/shared/schema.ts).
- [Release runbook](release.md): historical signing and distribution requirements for the retired application.
- [Dependency notice audit](third-party-notices.md) and [packaged notices](ThirdPartyNotices.txt): provenance for the former native dependencies.

Snapshot bodies retain their original paths and links to preserve the evidence.
Some targets were removed with the native application. Recover those files from
Git revision `75595d46e1d01b9499eaec8d83ff2431ee76ec8f`, for example:

```sh
git show 75595d46e1d01b9499eaec8d83ff2431ee76ec8f:PLAN.md
```

Historical GUI gates and commands must not be rerun or treated as pending work.
No historical failure or unexecuted check has been relabeled as passing.
