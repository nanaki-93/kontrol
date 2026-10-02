.DEFAULT_GOAL := build

.PHONY: install dev run build start typecheck test clean web-dev web-build web-start web-test

install:
	cd web && npm ci

# Local web dashboard. These commands do not launch a browser.
dev run web-dev:
	cd web && npm run dev

build web-build:
	cd web && npm run build

start web-start:
	cd web && npm start

typecheck:
	cd web && npm run typecheck

# package.json explicitly selects non-GUI Node test files.
test web-test:
	cd web && npm test

# Remove generated output only; retain local data, configuration and dependencies.
clean:
	rm -rf web/dist web/coverage
