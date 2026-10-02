# Local project format

Connect an absolute project-folder path in Projects. Kontrol reads UTF-8 files
inside that folder's `.kontrol` directory. The [complete example](examples/.kontrol/project.yaml)
also supplies isolated fixtures for the web persistence tests.

```text
project-root/
  .kontrol/
    project.yaml       # required
    roadmap.yaml       # optional
    context.md         # optional, read-only
    rules.md           # optional, read-only
    features/
      feature-id.md    # YAML frontmatter and Markdown body
```

`project.yaml` requires `schema_version: 1`, a stable `id` and a nonempty `name`.
Optional fields are `description`, `stack`, `goals` and `current_focus`:

```yaml
schema_version: 1
id: my-project
name: My project
description: A local web application
stack: [TypeScript, React]
goals: [Build a useful dashboard]
current_focus: [projects]
```

Each feature begins with frontmatter:

```markdown
---
id: project-reader
title: Read local project metadata
status: ready
priority: high
effort: small
depends_on: []
areas: [projects]
completed_at:
---
Describe the feature and its acceptance criteria here.
```

Feature `id`, `title`, `status`, `priority` and `effort` are required.
`schema_version`, when supplied, must be `1`. States are `planned`, `ready`,
`active`, `blocked` or `completed`; priorities are `high`, `medium` or `low`;
efforts are `small`, `medium` or `large`. Dependencies and areas default to empty
lists, and `completed_at` defaults to null. IDs must be unique and dependencies
must name existing features without cycles.

Up to three next features are selected from `ready` features whose dependencies
are all completed. Ordering uses current-focus area matches, then priority,
effort and feature ID. Invalid files and dependencies are reported separately;
valid independent features remain usable.

The optional roadmap requires `schema_version: 1` and a `milestones` array;
each milestone has `id`, `title` and `status` strings. Context and rules are
displayed as read-only notes, never executed as instructions.

Completing a recommended feature updates only its `status` and `completed_at`
frontmatter values, preserving unrelated fields, comments, body and line endings.
Completion requires simple scalars in block-style YAML. Digest comparisons reject
concurrent edits; Undo restores the previous bytes only if the file still matches
the completed revision. Undo is temporary and expires when the server restarts.
Disconnecting removes only the saved reference and never deletes project files.

Files are limited to 1 MB each and at most 500 Markdown feature files. Duplicate
YAML keys, aliases, unsupported schema versions, path traversal and symbolic links
inside `.kontrol` are rejected. The [server implementation](../web/server/modules/projects.ts)
defines the full validation and mutation behavior.
