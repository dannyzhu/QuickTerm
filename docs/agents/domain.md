# Domain docs

## Before exploring, read these

- Read `CONTEXT.md` in the repository root.
- Read whichever architecture decision records under `docs/adr/` bear on the work at hand.
- If a root-level `CONTEXT-MAP.md` ever appears, read the map first, then the contexts in it that relate to the current topic, plus their ADRs.

If a file isn't there, just carry on. Domain docs are created on demand by `domain-modeling`, once a term or a decision has actually settled.

## File structure

This project uses a **single-context** layout:

```text
/
├── CONTEXT.md
├── docs/adr/
│   └── NNNN-<decision>.md
└── Sources/
```

Those paths are a convention; the files appear as they are needed. `vendor/ghostty/` is a third-party dependency; it does not split the project's domain context.

## Use the glossary's vocabulary

When task titles, refactoring proposals, hypotheses and test names refer to a domain concept, use the term `CONTEXT.md` defines. If the concept you need isn't there, check what the project already calls it; if there is a genuine gap, write it down for `domain-modeling` to handle.

## Flag ADR conflicts

When a proposal conflicts with an existing ADR, name that ADR and explain why it is worth reopening.
