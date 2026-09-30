# F13 — Settings, accessibility, and V1 release

**Depends on:** all previous features. **Current status:** Settings/export and
release preparation implemented; integrated/native/runtime/distribution approval
pending. Dated results and historical failures/skips remain in [QA](../qa.md).
This is an executable app, not just a specification package; implementation
verification is not unconditional F13/V1 completion.

## Implemented behavior

- Main-window and native Command-comma Settings use the same `AppDependencies`
  container, existing feature stores and one transient export service. General,
  AI/Keychain, News, Projects and Learning answers remain separate state owners;
  navigation, editor drafts/revision baselines, confirmations and focus are
  per-client presentation state. Shared publications do not overwrite drafts.
- General preferences are typed/versioned: default 25 minutes, 15/25/50 presets
  or positive whole custom minutes, system/large text and system/reduced motion.
  Changes affect following ready Focus drafts, never existing sessions or frozen
  submitted retries. Missing storage supplies defaults without insertion;
  unreadable storage is not absence. Reduced motion combines system OR app;
  Large respects larger system sizes and avoids duplicate scaling. Black / Red
  Terminal is fixed, not a theme picker.
- AI, News and folder management reuse existing owners and screens. Opening
  Settings does not generate lessons or refresh feeds. Core saved daily/Learning
  loops and authorized local projects work without network/account; cached News
  stays available offline, while explicit refresh and optional AI need network.
- Folder listing/review/removal reads local references only. Remove captures
  name/ID/revision and disconnects durably before clearing that reference's
  transient state; it never accesses/deletes/edits external `.kontrol`, source or
  Git files. Stale/missing targets need explicit reload/review/reconfirmation;
  busy operations reject removal. Add/Reconnect reuse native authorization.
- Local Data exports [version-1 plain JSON](../export-format.md): tasks, blocks,
  all persisted Focus states, stored Learning taxonomy/accepted definitions,
  progress, exact saved answers/attempt milestones and available historical
  content, slots, terminal evidence, catalog membership, effective News topics/
  feeds and General/nonsecret AI configuration. Legacy absence is explicit null,
  never substituted current content; included corruption aborts the whole export.
- Credentials **and references**, project grants/paths/contents, cached articles,
  transport/diagnostics and unsaved editor drafts are structurally excluded.
  Authored sensitive-looking notes/answers remain exact. Protect the JSON: no
  import/restore or encrypted backup is provided.
- Native JSON approval/replacement confirmation precedes cancellation checks,
  existing pending-answer flush and synchronous read-only capture. Picker cancel
  performs no flush/capture/artifact/write; failed answer saves retain pending
  answers and abort (earlier individual saves may remain). Private encoding and
  validation run off-main; coordinated atomic delivery preserves existing bytes
  on pre-commit failure/cancel and reports saved after commit despite late cancel.
  Destination grants are transient; owned staging is cleaned, with cleanup failure
  explicitly identified. Duplicate requests cannot overlap; retries are explicit.
- Version/build **1.0/1**, Release hardening and narrow unchanged permissions,
  packaged pinned-source [dependency notices](../third-party-notices.md), and
  [installation/update/signing procedures](../release.md) are implemented.
  Local store/sidecar preservation and separate Keychain/folder boundaries are
  documented in [architecture](../architecture.md). Local project authoring
  starts at [docs/examples/.kontrol](../examples/.kontrol/project.yaml).

## Function → mockup contract

| Function / page | Dedicated visual | Expected behavior |
| --- | --- | --- |
| Edit settings and Focus default | [M38 · Settings](../mockups/M38-settings.png) | Apply locally; existing sessions retain duration; independent drafts survive publication. |
| Export local data | [M40 · Local data](../mockups/M40-data-export.png) | Native JSON approval, saved-answer barrier and actual commit outcome; no credential/grant fields. |
| Disconnect project folder | [M41 · Project folders](../mockups/M41-remove-project.png) | Remove local reference only; leave every external project file unchanged. |
| Accessibility and release verification | [M42 · Appearance](../mockups/M42-design-accessibility.png) | Verify all screens with keyboard, VoiceOver, text scaling and reduced motion. |

[Supplemental decision/outcome/layout states](../../.mockups/flows/f13-settings-release/index.html)
cover the shared hub, General drafts, folders and export lifecycle. Compiled
geometry/focus fixtures do not establish native rendering or spoken observations.

## Implementation evidence versus required release gates

The independent checkpoints in QA cover preferences/Focus isolation, revision-safe
local disconnect/callback fencing/external-byte preservation, export DTO/projections/
capture/IO/lifecycle/ownership, Settings routing and compiled adaptive/focus fixtures.
Step 5.1 explains and repairs the F11 mutable generated-store snapshot test boundary,
with rich V9→V10/reopen/repeat evidence and unchanged original fixture inventories;
the historical failed run remains recorded. Ten schemas/nine stages are preserved.
Steps 5.2–5.4 record metadata, hardening, resource/notice and executable-runbook
verification, not signed/native distribution approval. Step 5.5 records fresh
export test/JSON/link checks. Consolidated implementation integration remains next.

**F13/V1 release is done only when every mandatory gate has satisfactory evidence:**

- **A13:** reserve an active uncontended desktop and authorize the actual rebuilt
  test host; execute all deferred F00–F13 hosted tests and full serial suite,
  repair historical F02 AX/sheet/native-delete failures/skips, F06 hosted failures
  and F13 component prerequisite failures; compare native mockup captures at
  520×340 Settings and 1000×700/1440×940 desktop sizes, standard/130%/larger text.
  Independently observe keyboard-only journeys, visible/restored focus, spoken
  VoiceOver, reduced motion, non-color status, ≥32-point targets, text contrast
  ≥4.5:1 and essential focus/boundaries ≥3:1. Compilation/HTML is not acceptance.
- **S13:** on authorized isolated signed sandbox data, perform offline daily and
  Learning answer/history/relaunch loops, real picker/bookmark/project completion/
  Undo/conflict/revoke/reconnect/disconnect and native export cancel/replacement/
  failure/success. Inspect actual Release entitlements/resources; no debugging
  entitlement or Debug recovery injection. Optional AI/News failures preserve
  core data; no paid generation without separate authorization.
- **B13:** execute applicable checks/journeys on actual **macOS 14 and current
  supported runtime**. An unavailable baseline is a blocker, not an optional pass
  or something established by the deployment minimum.
- **D13:** external authorized Developer ID/team/notary inputs, accepted-only
  notarization, staple/Gatekeeper, final ZIP/checksum/extraction and strict repeat
  verification; fresh install/non-destructive update and selected-folder completion
  using the final extracted artifact. Ad-hoc/unsigned packaging is not distribution
  approval. See the exact guarded commands in the release runbook.

Unavailable manual observations stay labeled unavailable; previously failed/skipped
checks are not erased or converted into passes. Missing desktop authorization,
required runtime access or signing credentials blocks its gate, not independent
implementation checks. No F13/V1 completion claim is made before all gates pass.

## Visual references

![M38 · Settings](../mockups/M38-settings.png)

![M40 · Local data](../mockups/M40-data-export.png)

![M41 · Project folders](../mockups/M41-remove-project.png)

![M42 · Appearance](../mockups/M42-design-accessibility.png)

[Back to PLAN](../../PLAN.md) · [All screens](../mockups/INDEX.md) · [Data contracts](../architecture.md)
