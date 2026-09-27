# F11 — Complete a project feature

**Depends on:** F09, F10.

**Build**

- A visible `Mark complete` action changes the selected feature file's frontmatter `status` to `completed` and adds `completed_at` in ISO 8601 UTC. It updates only that file; preserve its body, comments, unknown frontmatter fields, and newline style.
- Read the file immediately before writing, detect an external edit since the card was loaded, and ask to refresh rather than overwrite it. Use coordinated, atomic replacement in the selected folder; show a failure without claiming completion if the write fails.
- Refresh progress and next-feature cards after success. Provide an `Undo` action that restores the previous status and removes `completed_at` when appropriate.
- Never edit source code, roadmap, git state, or GitHub as a side effect.

**Done when:** the on-disk Markdown change is minimal and reviewable, downstream features become eligible, undo works, and conflicting external edits are never lost.

## Function → mockup contract

| Function / page | Dedicated visual | Expected behavior |
| --- | --- | --- |
| Mark feature complete and update cards | [M31 · Kontrol](../mockups/M31-feature-completion-undo.png) | Persist to its Markdown frontmatter before showing success. |
| Undo completion | [M31 · Kontrol](../mockups/M31-feature-completion-undo.png) | Restore the immediately previous status only if the saved revision still matches. |
| Recover from conflict or write failure | [M32 · Kontrol](../mockups/M32-project-write-conflict.png) | Refresh rather than overwriting a changed file; no optimistic success. |

## Implementation checklist

- [ ] Capture source digest when reading a feature. Re-read and compare digest inside a coordinated write.
- [ ] Patch only top-level status and completed_at scalar ranges; preserve unknown keys, comments, body and line endings. If safe patching is impossible, fail visibly.
- [ ] Write a sibling temporary file, validate resulting YAML, replace atomically, then reread and update the view.
- [ ] Store a short-lived undo patch plus post-write digest; refuse undo if another editor has changed the file.
- [ ] Serialize writes per project. Do not update history.yaml, roadmap, code or Git.

## Acceptance checks

- [ ] Byte diff contains only intended frontmatter changes.
- [ ] A conflicting external edit remains intact and produces M32.
- [ ] Permission failure, disk failure or failed verification never increments completion count.

## Visual references

![M31 · Kontrol](../mockups/M31-feature-completion-undo.png)

![M32 · Kontrol](../mockups/M32-project-write-conflict.png)

[Back to PLAN](../../PLAN.md) · [All screens](../mockups/INDEX.md) · [Data contracts](../architecture.md)
