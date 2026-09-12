# QuickTerm

## Agent skills

### Issue tracker

Decision maps, specs and tasks live locally in `.scratch/<effort>/`; read [docs/agents/issue-tracker.md](docs/agents/issue-tracker.md) before creating, reading, claiming or resolving a task.

### Triage labels

The project uses the five default triage labels; read [docs/agents/triage-labels.md](docs/agents/triage-labels.md) before triaging a task or changing its triage status.

### QuickTerm control plane (CLI / AI agent)

QuickTerm ships a Unix-socket control plane and the `quickterm` command-line tool; read [docs/agents/quickterm-cli.md](docs/agents/quickterm-cli.md) before driving screens / workspaces / panes, or before giving an agent a control interface.

### Domain docs

Single-context layout: `CONTEXT.md` in the repository root plus `docs/adr/`; read [docs/agents/domain.md](docs/agents/domain.md) before exploring the code or discussing a domain decision.

## House rules

### Language

The project is English-first. Simplified Chinese exists only where the app itself is bilingual, and only in the places listed below.

- **Code comments, log messages (OSLog) and commit messages: English.** This is the whole rule — there is no bilingual half for any of them.

- **User-facing UI strings only through the catalogs**: `Resources/en.lproj` + `Resources/zh-Hans.lproj`, both languages in the same change, never a literal in a view. The rules the catalogs are held to (they are spelled out in the header of `Resources/en.lproj/Control.strings` and of `Sources/Localization/Localization.swift`):
  - English is the base language. Every key must exist in `en.lproj`; a key missing from another language falls back to the English value, never to the raw key.
  - One area owns one table (`Control.strings`, `Menus.strings`, …) and every `*.strings` file in a `.lproj` is merged at runtime, so parallel translation passes each add their own file. A key declared by two tables of the same language is a bug.
  - Keys are lowercase, dot-separated, area first: `<area>.<subject>.<detail>`. One key is one whole sentence or one whole label — never a fragment that code glues onto something else.
  - The only format specifiers are positional (`%1$@`, `%2$@`, …); a literal percent sign is `%%`. A string that varies with a count comes as a `.one` / `.other` pair, read through `Lp(_:count:_:)`.
  - A new table file has to be added to **both** `.lproj` folders and `xcodegen generate` re-run — the project is generated from `project.yml`, and a table that is not in the project is never copied into the bundle.
  - `scripts/check-localization.py` (a build phase of the QuickTerm target, so it runs on every build) and `Tests/LocalizationTests.swift` must both pass.

- **English, never localized**: the `quickterm` CLI (`--help` included), `describe` output, MCP tool descriptions, wire identifiers, config keys and pane handles. They do not follow `[general] language`, they are not in the catalogs, and an agent reading them gets the same text whatever the UI is drawn in. The AppKit `undo` / `redo` selector names are exempt for the same reason.

- **`WMAction` and `ConfigSchema` keep a hard-coded ZH/EN pair on purpose** — do not move them into the catalogs. They are compiled into the `quickterm` tool target as well, which has no AppKit and no `.lproj` directories; they are also the source of the config-file template (whose comments follow the UI language, via `ConfigSchema.templateLanguage`) and of the CLI's English text, since `describe --json` and the MCP tool table hand out *both* wordings at once. Edit a description and edit both halves.

A CJK grep over `Sources/` should therefore only hit those two files, the template header in `ConfigStore.swift`, and the Chrome Web Store button text a regex matches in `BrowserExtensionUI.swift` — that last one is web-page data, not a UI string.

### Docs

Documentation is written in English. The two READMEs are the exception and stay as they are: `README.md` English, `README.zh-CN.md` Simplified Chinese, kept line-parallel so a change to one is a change to the other.
