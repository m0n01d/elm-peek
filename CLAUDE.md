# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status

**Scaffold only — nothing works end-to-end yet.** `Server.res`, `Elmq.res`, and `ContentScript.res` are stubs with `TODO`s pointing at the contract in `SPEC.md`. Read `SPEC.md` first — it is the source of truth for the wire protocol, architecture, error codes, and v1 vs v2 scope. The README is intentionally thin and defers to the spec.

## Commands

```sh
bun install
bun run build:res          # compile ReScript (writes .res.mjs alongside sources, in-source)
bun run build:res:watch    # rescript -w
bun run clean              # rescript clean
bun run dev:server         # bun --watch run server/src/Server.res.mjs  (must build first)
```

The README mentions `build:ext` / `dev:ext` (Vite) scripts that aren't in `package.json` yet — the extension currently has no bundler step. The `manifest.json` loads `src/ContentScript.res.mjs` directly, and the `extension/dist/` path in the README setup steps doesn't exist yet either. Add a bundler before the extension can ship.

There are no tests, no linter, and no formatter configured.

## Style guide (non-negotiable)

### TEA-style state management

All stateful code follows The Elm Architecture. For any component or module with non-trivial state:

- Define `type model = ...` (the full state shape).
- Define `type msg = ...` (a variant enumerating every transition).
- Write a pure `let update = (msg, model) => newModel`.
- Render with `let view = model => React.element` (or the equivalent for non-React modules).
- In React, drive this with `React.useReducer(update, initialModel)` — **do not** sprinkle `useState` / `useEffect` for state that belongs in `model`.
- Side effects (HTTP, DOM, timers) happen in response to a dispatched `msg`, not inline during render. If the side-effect surface grows, model an Elm-style `Cmd` rather than smuggling effects through refs.

`Tooltip.res`'s `state` variant (`Loading | Ok | NotFound | Error`) is the shape new code should follow.

### No escape hatches

The whole reason ReScript is here is type safety across the extension ↔ server ↔ elmq boundaries. **Never** use:

- `%raw` / `%%raw`
- `Obj.magic`
- Untyped `{..}` object types passed to `external` (the `Server.res` Bun bindings currently do this — that's a wart to clean up, not a pattern to copy)
- String-keyed dynamic access (`Dict.get` in place of a typed record)

When you need a JS API:

1. First look for an existing binding package (`rescript-webapi`, `@rescript/react`, `@rescript/core`, community packages on npm) and install it.
2. If nothing exists, write properly typed `@scope` / `@val` / `@send` / `@new` `external`s with concrete record types — never `{..}`. Keep bindings in a dedicated module (e.g., `Bun.res`, `Bindings/Foo.res`) so they're easy to audit.
3. A few extra lines of binding code pays for itself the first time a field is renamed.

## Architecture

Three processes, one direction of data flow:

```
GitHub page (content script)  ──HTTP──▶  localhost:42069 (Bun server)  ──spawn──▶  elmq CLI
```

- **Extension** (`extension/`): Manifest V3 content script injected on `github.com/*/blob/*`, `pull/*/files*`, and `commit/*`. Detects capitalized identifier spans in rendered Elm files, debounces hover/click, fetches `/lookup`, mounts a React tooltip.
- **Server** (`server/`): `Bun.serve` on `127.0.0.1:42069`. Single `GET /lookup?repo=&symbol=&module=&ref=` endpoint. Reads `~/.config/elm-peek/repos.json` to map `org/name` → local checkout path. Spawns `elmq grep --definitions --source --format json '^<symbol>$' <repoPath>` and returns parsed results.
- **elmq**: external CLI on `$PATH`, does the actual symbol resolution against the local repo checkout.

The whole system is **localhost-only, single-user, no auth**. Security relies on `127.0.0.1` binding + tight CORS (`Access-Control-Allow-Origin: https://github.com` exact) + arg-array spawn (no shell). Don't relax any of these — see `SPEC.md#security`.

### Wire protocol invariants

The response shape is fixed by `SPEC.md`. Both the extension and the server must agree on it:

- Success: `{ "kind": "ok", "results": [{ symbol, module, file, line, source }] }` — `results` is always an array; multiple matches are normal (disambiguation handled in the tooltip).
- Error: `{ "kind": "error", "reason": <code>, "detail": <string> }` — reason codes are an enum: `repo-not-mapped`, `not-found`, `elmq-failed`, `bad-request`. The extension branches on `reason`; don't add new codes without updating both sides.

Note: the `result` record uses `module_` in ReScript (since `module` is reserved). The JSON wire field is `module`.

### v1 vs v2 scope

v1 is deliberately dumb: server gets a bare symbol, runs one `elmq grep`, returns every hit. v2 adds import-aware resolution (extension parses imports, server narrows candidates, handles qualified accesses and `exposing` lists). Don't pull v2 work into v1 — `SPEC.md` is explicit about shipping the 80% case first.

## ReScript build setup

This project targets **ReScript 12** (`^12.3.0`). A single `rescript.json` at the repo root compiles **both** `extension/src` and `server/src`. Notable config:

- `package-specs: esmodule` + `in-source: true` + `suffix: .res.mjs` → compiled output lands next to each `.res` file (e.g., `Server.res` → `Server.res.mjs`). The `dev:server` script runs the compiled output directly under Bun; there is no separate bundler for the server.
- **No `@rescript/core` dependency, no `-open RescriptCore`.** In ReScript 12 the new standard library ships inside the compiler as `Stdlib` and is available globally. The pre-12 setup of installing `@rescript/core` and opening it via `bsc-flags` is gone — don't add either back.
- `jsx.version: 4, mode: automatic` for `@rescript/react` (which is itself v12-only and peer-deps React 19).
- `warnings.error: "+101"` → unused-open and friends are hard errors.

`.gitignore` excludes `*.res.mjs` and `lib/`, so compiled output is never committed. When grepping, search `.res` sources, not the `.res.mjs` siblings.

### v11 → v12 idioms to watch for

If you copy code from older ReScript snippets, expect to update:

- `*Exn` APIs → `*OrThrow` (e.g., `Array.getExn` → `Array.getOrThrow`).
- `Exn.Error(e)` pattern → `JsExn(e)`.
- OCaml-era helpers (`succ`, `pred`, `raise`, `Pervasives.*`) → JS equivalents.
- Anything that explicitly references `RescriptCore.*` → just drop the prefix; it's `Stdlib.*` (auto-available).

## Token detection (extension) — gotchas worth remembering

`SPEC.md#token-detection-extension` calls these out, and they will bite anyone who skips it:

- **Don't pin to GitHub class names.** They churn with redesigns. Filter `<span>` elements by `textContent` matching `/^[A-Z][A-Za-z0-9_]*$/` instead.
- **Skip strings and comments.** Capitalized words inside `.pl-s` / `.pl-c` (or whatever GitHub uses at runtime) are false positives.
- **Don't re-bind on every mutation.** Use a `MutationObserver` + `WeakSet` of already-bound elements — GitHub's diff view re-renders aggressively.
- Hover: 200ms debounce before fetch; show loading state only after 300ms to avoid flicker.
- Keep selector logic isolated in one module so GitHub redesigns are a localized fix.
