# Kontrol

A local web dashboard for Tasks, Planner, Focus, Learning, Projects, News and JOB.
Each module has its own page and dashboard widgets you can show, hide, resize and
reorder. React and TypeScript provide the interface; a Node/Express server stores
your data in SQLite on this computer.

## Getting started

Install Node **22.13 or later**, then run from the repository root:

```sh
make install
make dev
```

Open **http://127.0.0.1:4310**. The server binds to loopback and serves the interface
and API from one process. It prints the address without opening a browser.
Keep the process running while using Kontrol.

For the production frontend, run `make build`, then `make start`. These commands
are also available directly in `web/` as `npm ci`, `npm run dev`, `npm run build`
and `npm start`.

## What is included

- Tasks, daily planning and Focus sessions with persistent history.
- Forty offline lessons, saved answers, self-checks and learning coverage.
- Local `.kontrol` project inspection, next-feature suggestions, completion and Undo.
- News interests, cross-publisher search and optional RSS/Atom subscriptions.
- JOB CV extraction, reviewed profiles, city/work filters and ranked job offers.
- Dashboard customization, preferences, JSON backup and validated import.

News AI and JOB analysis use your existing **PI** installation, login and saved
model. Configure PI before using those actions; Kontrol does not collect an API
key. See the [setup and module guide](docs/web-app.md) for configuration, source
coverage and feature limits.

## Data and configuration

The default database is `web/.data/kontrol.sqlite`. Keep its WAL/SHM sidecars
with it. `KONTROL_DATA_DIR` selects an independent data directory;
`KONTROL_PORT` changes the default port. Optional PI overrides go in `web/.env`,
using [web/.env.example](web/.env.example) as a starting point. Local data,
credentials, dependencies and generated output are ignored by Git.

Settings exports version-3 web backups and imports previous web backups or
legacy macOS version-1 JSON exports into an empty workspace. Backups contain
unencrypted personal content, including extracted CV text. Reconnect project
folders separately. See [data migration and backup details](docs/web-app.md#move-existing-data).

## Development

| Command | Purpose |
| --- | --- |
| `make install` | Install the locked npm dependencies. |
| `make dev` / `make run` | Start the local development server. |
| `make build` | Check TypeScript and build the production frontend. |
| `make start` | Serve the built frontend and API. |
| `make typecheck` | Check TypeScript without building assets. |
| `make test` | Run the explicitly selected non-GUI Node test files in `web/package.json`. |
| `make clean` | Remove only `web/dist` and `web/coverage`; retain local data and configuration. |

The previous `make web-dev`, `web-build`, `web-start` and `web-test` aliases remain
available. Tests use in-memory or temporary databases, copied project fixtures
and injected network responses. The optional installed-PI fixture test requires
`KONTROL_TEST_PI_COMMAND` pointing to a PI executable; otherwise that test is
reported as skipped. Follow [AGENTS.md](AGENTS.md) and inspect test selections
before running them. See [validation evidence](docs/validation.md) for actual
commands and results.

Application code, schemas, tests and bundled catalogs live under [web/](web/).
The Swift/Xcode application and its build tooling have been removed. Historical
validation records remain in the [native archive](docs/archive/native/README.md).

- [Architecture and extension points](docs/web-app.md#architecture-and-extension)
- [Local project format](docs/project-format.md) and [example project](docs/examples/.kontrol/project.yaml)
- [Learning curriculum](docs/learning-curriculum.md)
- [Third-party notices](docs/third-party-notices.md)
