# elm-peek

Hover/click an Elm type on GitHub → see its definition inline. Personal tool.

See [SPEC.md](./SPEC.md) for the design.

## Status

Scaffold only. Nothing works yet.

## Layout

```
elm-peek/
├── SPEC.md                  design doc — start here
├── extension/               browser extension (Manifest V3)
│   ├── manifest.json
│   └── src/
│       ├── ContentScript.res    injected into github.com pages
│       └── Tooltip.res          React tooltip component
└── server/                  local HTTP server (Bun + ReScript)
    ├── config.example.json
    └── src/
        ├── Server.res            HTTP server (Bun.serve)
        └── Elmq.res              wrapper around `elmq` subprocess
```

## Prereqs

- [Bun](https://bun.sh) 1.3+
- [elmq](https://github.com/...) on PATH
- Chrome or Firefox (extension is Manifest V3)

## Setup (eventually)

```sh
bun install
bun run build:res        # compile ReScript
bun run build:ext        # bundle extension to extension/dist/
```

Then:

1. `cp server/config.example.json ~/.config/elm-peek/repos.json` and edit.
2. `bun run dev:server` to start the local server.
3. Chrome → `chrome://extensions` → Load unpacked → `extension/dist/`.
4. Visit a `.elm` file or diff on GitHub.

## Dev

```sh
bun run build:res:watch   # rescript -w
bun run dev:ext           # vite build --watch
bun run dev:server        # bun --watch server entry
```
