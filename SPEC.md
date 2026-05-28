# elm-peek — Spec

Personal browser extension + local server that lets you hover/click on an Elm type identifier in GitHub's blob or diff view and see its definition inline, without leaving the tab.

Resolves cross-module references by running `elmq` against your local checkout of the repo you're viewing.

## Why this exists

GitHub's built-in "code navigation" (the symbol panel + hover) only covers ~10 languages via stack-graphs — Elm isn't one of them. For codebases with hundreds of modules, opening a separate editor or jumping around in GitHub's file tree just to read a type definition during PR review is friction worth eliminating.

## Goals

- **Hover or click** an uppercase identifier on a GitHub Elm file page → inline panel with the definition.
- **Cross-module resolution.** Works whether the type is in the same file, another file in the repo, or (eventually) an Elm package dependency.
- **Both blob view and diff view.** Diff view (PR "Files changed" tab) is the primary use case — that's where review actually happens.
- **Personal use only.** No web-store distribution, no multi-user concerns, no telemetry.

## Non-goals

- Public release on Chrome Web Store / Firefox AMO.
- Running without a local checkout of the repo being viewed.
- Editing from the panel. Read-only.
- Supporting languages other than Elm.
- Working on GitHub Enterprise (could be added later via host config).

## Architecture

```
┌──────────────────────────┐         ┌──────────────────────┐         ┌────────┐
│ Chrome / Firefox         │         │ localhost:42069      │         │ elmq   │
│ (github.com/*/blob/*.elm │  HTTP   │ Bun + ReScript       │  spawn  │ subproc│
│  github.com/*/pull/*/    │ ───────▶│ HTTP server          │ ───────▶│        │
│  files)                  │         │                      │         │        │
│                          │◀─────── │                      │◀────────│        │
│ ┌──────────────────────┐ │  JSON   │                      │  stdout │        │
│ │ content script       │ │         │                      │         │        │
│ │  - token detection   │ │         │                      │         │        │
│ │  - hover / click     │ │         │                      │         │        │
│ │  - React tooltip     │ │         │                      │         │        │
│ └──────────────────────┘ │         │                      │         │        │
└──────────────────────────┘         └──────────┬───────────┘         └────────┘
                                                │
                                                ▼
                                  ~/.config/elm-peek/repos.json
                                  ─────────────────────────────
                                  { "org/foo": "/Users/me/code/foo" }
```

## Wire protocol

Single endpoint. Keep it dumb.

### Request

```
GET /lookup?repo=<org>/<name>&symbol=<id>&module=<dotted>&ref=<sha-or-branch>
```

- `repo` (required): GitHub `org/name`, extracted from URL.
- `symbol` (required): the token the user hovered/clicked. E.g. `InstanceStep`.
- `module` (optional, v2): the dotted module name of the file the user is viewing. Used to disambiguate when v2 import-resolution lands.
- `ref` (optional): branch name or SHA from URL. v1 ignores it (uses `HEAD` of local checkout). v2 may `git show <ref>:path`.

### Response — success

```json
{
  "kind": "ok",
  "results": [
    {
      "symbol": "InstanceStep",
      "module": "Model.Process.InstanceStep",
      "file": "src/Model/Process/InstanceStep.elm",
      "line": 42,
      "source": "type alias InstanceStep =\n    { id : InstanceStepId\n    , ...\n    }"
    }
  ]
}
```

Multiple results are possible (same identifier defined in different modules). The extension renders a disambiguation list when `results.length > 1`.

### Response — error

```json
{ "kind": "error", "reason": "repo-not-mapped", "detail": "org/foo not in repos.json" }
```

Reason codes:

| reason            | meaning                                                  | extension behavior                            |
|-------------------|----------------------------------------------------------|-----------------------------------------------|
| `repo-not-mapped` | Repo isn't in `repos.json`.                              | Show panel with "Configure this repo" button. |
| `not-found`       | No declaration with that name in the repo.               | Show panel: "No definition found."            |
| `elmq-failed`     | `elmq` exited non-zero or returned malformed output.     | Show panel with error detail.                 |
| `bad-request`     | Missing required query params.                           | Log to console, no panel.                     |

## Repo resolution (server)

The server reads `~/.config/elm-peek/repos.json` at startup and on SIGHUP:

```json
{
  "org/foo": "/Users/me/code/foo",
  "org/elm-browser": "/Users/me/code/elm-browser"
}
```

If the requested `repo` isn't a key, return `repo-not-mapped`. No fuzzy matching — keep it explicit so the user controls which checkouts get exposed.

## Symbol resolution (v1)

v1 punts on import resolution to ship fast:

1. Extension sends `symbol=<bare-name>`, no module context.
2. Server invokes:
   ```
   elmq grep --definitions --source --format json '^<symbol>$' <repo-path>
   ```
3. Server parses elmq's JSON, returns all matches as the `results` array.
4. Extension shows a list if `results.length > 1`.

This will sometimes return multiple hits (same identifier in different modules). That's acceptable — disambiguation is one click. The 80% case (unique type name) just works.

## Symbol resolution (v2, future)

Add real import awareness so we don't show false positives:

1. Extension parses imports from the file it's looking at and sends them.
2. Server uses the import map to narrow `elmq grep` to candidate files.
3. For qualified accesses (`Foo.Bar`), resolve `Foo` through the alias map before lookup.
4. For bare accesses, check `exposing (Bar)` lists across imports.

## Token detection (extension)

Two GitHub view types to handle. Both render `.elm` files with syntax highlighting, but DOM differs:

- **Blob view** (`/blob/<ref>/path/file.elm`): tokens are individual `<span>` elements inside the file's rendered table. The exact class names change with GitHub redesigns, so we should not pin to specific class names. Instead: find the file container, then `querySelectorAll('span')` filtered by text content matching `/^[A-Z][A-Za-z0-9_]*$/`.
- **Diff view** (`/pull/<n>/files`, `/commit/<sha>`): similar token spans inside each diff cell. Each `+`/`-` line is a separate row. Filter the same way.

Edge cases:
- Strings and comments contain capitalized words too — must skip tokens inside `.pl-s` (string) or `.pl-c` (comment) classes (or whatever GitHub uses; check at runtime).
- Avoid re-binding on every DOM mutation — use a MutationObserver and `WeakSet` of already-bound elements.

Hover handler:
- Debounce 200ms before firing lookup.
- Show loading state in tooltip after 300ms (avoid flicker for fast responses).

## Tooltip UX

- Position: below the token, fall back to above if it would go off-screen.
- Width: 480px default, expandable.
- Content:
  - Header: `module.SymbolName` + small "open in editor" button (v2, deep-link).
  - Body: syntax-highlighted source.
  - Footer (if multiple results): list of other matches.
- Dismiss: outside click, Esc, or hovering away after a delay.
- Toggle interaction model:
  - Hover = preview (auto-dismiss).
  - Click = pinned (must explicitly dismiss).

## Security

- Server binds to `127.0.0.1` only — not `0.0.0.0`. Nothing on LAN can reach it.
- CORS: `Access-Control-Allow-Origin: https://github.com` exact match, no wildcards.
- `elmq` is invoked with arg arrays (no shell), so no command injection from the `symbol` param.
- Server only reads files within configured repo paths — never writes, never executes user code.
- No shared secret needed for v1; localhost-only + tight CORS is enough for a single-user tool.

## Stack

- **Extension**: Manifest V3, ReScript + `@rescript/react`, Vite for bundling, no background script needed (content script does its own fetches).
- **Server**: Bun + ReScript. Bun's built-in `Bun.serve` for HTTP, `Bun.spawn` for invoking elmq. No framework.
- **Build**: One `rescript.json` at root compiles both subprojects. Vite bundles the extension. Server runs compiled `.res.mjs` directly under Bun.

## Open questions

- **Token recognition without parsing the file.** Capitalized identifiers in Elm can be types, constructors, or module-name segments. v1 treats them all the same and lets elmq sort it out. If false positives become annoying, the extension could pre-filter by checking whether the parent span has a "type" syntax class.
- **Caching.** elmq is fast enough that v1 doesn't need a cache. If it becomes an issue, cache `(repo, symbol)` → result in the server, invalidated on file mtime change.
- **GitHub redesigns.** Token DOM selectors will break periodically. Plan for it: keep selector logic isolated in one module so updates are mechanical.

## Future work (not in v1)

- Deep-link "open in editor" via `vscode://` or similar.
- `elmq refs`-powered "find usages."
- Show declaration docstrings.
- Package types via `package.elm-lang.org/packages/<author>/<pkg>/<ver>/docs.json`.
- GitHub Enterprise support (extra host pattern in manifest + per-host repo maps).
- Firefox build (mostly free with Manifest V3, just a few `browser` vs `chrome` API differences).
