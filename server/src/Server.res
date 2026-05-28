// Local HTTP server. Binds 127.0.0.1:42069, single GET /lookup endpoint.
// Spec: ../../SPEC.md (Wire protocol section).
// Style: CLAUDE.md (no %raw, no untyped {..} externals — use Bun.res bindings,
// Stdlib only, no Js.Dict/Js.Console/Js.Int).
//
// P1 Track A — Slice 0 walking skeleton. The handler returns a hard-coded
// fake definition for any GET /lookup, handles the CORS preflight, and
// 404s everything else. Slice 1 (P2) parses the query + reads repos.json;
// Slice 2 (P3-C) wires in real elmq. Each phase only adds branches above
// the catch-all fallback.

open Bun

// --- Config ----------------------------------------------------------------

let port = 42069
let hostname = "127.0.0.1"

// --- CORS ------------------------------------------------------------------

// SPEC.md#security: exact Origin match, never wildcards. Methods/headers
// kept minimal — only what /lookup actually needs.

let corsOrigin = "https://github.com"

let corsHeadersJson: dict<string> = Dict.fromArray([
  ("Content-Type", "application/json"),
  ("Access-Control-Allow-Origin", corsOrigin),
  ("Access-Control-Allow-Methods", "GET, OPTIONS"),
  ("Access-Control-Allow-Headers", "Content-Type"),
])

let corsHeadersPreflight: dict<string> = Dict.fromArray([
  ("Access-Control-Allow-Origin", corsOrigin),
  ("Access-Control-Allow-Methods", "GET, OPTIONS"),
  ("Access-Control-Allow-Headers", "Content-Type"),
])

// --- Response constructors ------------------------------------------------

let jsonResponse = (status: int, payload: Wire.response): response =>
  makeResponse(Wire.encode(payload), {status, headers: corsHeadersJson})

let preflightResponse = (): response =>
  makeEmptyResponse(Null.null, {status: 204, headers: corsHeadersPreflight})

let notFoundResponse = (detail: string): response =>
  jsonResponse(404, Wire.Err({reason: Wire.NotFound, detail}))

// --- URL parsing ----------------------------------------------------------

// Bun's request.url is the full URL; we only need the pathname for routing
// in Slice 0. Strip the query (everything from '?' onward).
let stripQuery = (url: string): string =>
  switch String.indexOf(url, "?") {
  | -1 => url
  | qIdx => String.slice(url, ~start=0, ~end=qIdx)
  }

let pathOf = (url: string): string => {
  let withoutQuery = stripQuery(url)
  let len = String.length(withoutQuery)
  switch String.indexOf(withoutQuery, "://") {
  | -1 => withoutQuery
  | i =>
    let rest = String.slice(withoutQuery, ~start=i + 3, ~end=len)
    let restLen = String.length(rest)
    switch String.indexOf(rest, "/") {
    | -1 => "/"
    | j => String.slice(rest, ~start=j, ~end=restLen)
    }
  }
}

// --- Handler --------------------------------------------------------------
//
// `makeHandler` is a factory so tests can inject a fixture config path AND a
// stub elmq binary without touching `~/.config/elm-peek/repos.json` or the
// real CLI. The default `handle` reads from `Config.defaultPath` and resolves
// `elmq` through `$PATH`. New routing branches go ABOVE the catch-all 404s
// per CLAUDE.md/plan insertion-point convention.

let makeHandler = (
  ~configPath: string=Config.defaultPath,
  ~elmqBin: string=Elmq.defaultBin,
): (request => promise<response>) =>
  req => {
    let method = requestMethod(req)
    let url = requestUrl(req)
    let path = pathOf(url)

    switch (method, path) {
    | ("OPTIONS", _) => Promise.resolve(preflightResponse())
    | ("GET", "/lookup") =>
      switch UrlParse.parse(url) {
      | Error(reason) =>
        Promise.resolve(
          jsonResponse(400, Wire.Err({reason, detail: "missing or empty required query params"})),
        )
      | Ok({repo, symbol, file, module_, _}) =>
        switch Config.lookup(~configPath, ~repo) {
        | None =>
          Promise.resolve(
            jsonResponse(
              404,
              Wire.Err({reason: Wire.RepoNotMapped, detail: `${repo} not in repos.json`}),
            ),
          )
        | Some(repoPath) =>
          Elmq.lookup(~repoPath, ~symbol, ~elmqBin, ~file?, ~module_?)->Promise.then(result =>
            switch result {
            | Ok([]) =>
              Promise.resolve(
                jsonResponse(
                  404,
                  Wire.Err({reason: Wire.NotFound, detail: `no definition for ${symbol}`}),
                ),
              )
            | Ok(results) => Promise.resolve(jsonResponse(200, Wire.Ok({results: results})))
            | Error(reason) =>
              Promise.resolve(
                jsonResponse(
                  500,
                  Wire.Err({reason, detail: `elmq failed for symbol ${symbol}`}),
                ),
              )
            }
          )
        }
      }
    | ("GET", p) => Promise.resolve(notFoundResponse(`no route for GET ${p}`))
    | (m, p) => Promise.resolve(notFoundResponse(`no route for ${m} ${p}`))
    }
  }

let handle: request => promise<response> = makeHandler()

// --- TLS -------------------------------------------------------------------
//
// Safari blocks https://github.com → http://127.0.0.1 as mixed content even
// for localhost. To make the extension usable in Safari (and harmless in
// Chrome/Firefox), we run TLS when both cert+key files exist at the default
// paths. Generate them with:
//
//   brew install mkcert && mkcert -install
//   mkcert -cert-file ~/.config/elm-peek/cert.pem \
//          -key-file  ~/.config/elm-peek/key.pem  localhost 127.0.0.1
//
// If either file is missing, boot plaintext HTTP and log a warning so the
// operator knows Safari won't work.

@module("node:fs") external readFileSync: (string, string) => string = "readFileSync"
@module("node:fs") external existsSync: string => bool = "existsSync"
@scope(("process", "env")) @val external homeEnv: Null.t<string> = "HOME"

let tlsConfig: unit => option<tlsOptions> = () => {
  let home = switch Null.toOption(homeEnv) {
  | Some(h) => h
  | None => ""
  }
  let certPath = `${home}/.config/elm-peek/cert.pem`
  let keyPath = `${home}/.config/elm-peek/key.pem`
  if existsSync(certPath) && existsSync(keyPath) {
    switch (readFileSync(certPath, "utf8"), readFileSync(keyPath, "utf8")) {
    | (cert, key) => Some({cert, key})
    | exception _ =>
      Console.error(`[elm-peek] failed to read TLS cert/key, falling back to HTTP`)
      None
    }
  } else {
    None
  }
}

// --- Boot ------------------------------------------------------------------
//
// Guarded so importing this module from tests does not bind port 42069.
// `import.meta.main` is true only when this file is the entry point.

@val external importMetaMain: bool = "import.meta.main"

if importMetaMain {
  let s = switch tlsConfig() {
  | Some(tls) => serve({port, hostname, tls, fetch: handle})
  | None => serve({port, hostname, fetch: handle})
  }
  // SIGHUP: spec mentions it as the cache-reload mechanism. Slice 1 reads
  // the config file on every lookup, so this is a logging breadcrumb only.
  // Why: keeps the wiring in place for when caching lands without changing
  // operator UX (kill -HUP <pid> still does something visible).
  Config.onSighup(() => Console.log("[elm-peek] SIGHUP received (no cache to reload yet)"))
  let scheme = switch tlsConfig() {
  | Some(_) => "https"
  | None => "http"
  }
  Console.log(`[elm-peek] listening on ${scheme}://${hostname}:${Int.toString(serverPort(s))}`)
  if scheme === "http" {
    Console.log("[elm-peek] HTTP mode — Safari will block requests as mixed content.")
    Console.log("[elm-peek] Generate certs with: mkcert -install && mkcert -cert-file ~/.config/elm-peek/cert.pem -key-file ~/.config/elm-peek/key.pem localhost 127.0.0.1")
  }
}
