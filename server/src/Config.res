// Loads the user's repo→path map from ~/.config/elm-peek/repos.json.
// Spec: SPEC.md#repo-resolution-server.
//
// Slice 1 design choice (KISS): read the file from disk on every `lookup`
// call. It's a few KB of JSON on a single-user, localhost-only tool — there
// is no measurable cost. SIGHUP is wired purely as a logging hook for now
// because there's no cache to invalidate. If/when caching shows up, the
// SIGHUP handler is the natural place to clear it.
//
// Why no `Belt`, no `@rescript/core`: per CLAUDE.md, Stdlib only (ReScript
// 12's global stdlib).

// --- fs bindings (file-scoped; trivial enough to keep inline) ------------

@module("node:fs") external readFileSync: (string, string) => string = "readFileSync"
@module("node:fs") external existsSync: string => bool = "existsSync"

// --- process bindings (for HOME + SIGHUP) --------------------------------

@scope(("process", "env")) @val external homeEnv: Null.t<string> = "HOME"
@scope("process") @val external onSignal: (string, unit => unit) => unit = "on"

// --- Public API ----------------------------------------------------------

let defaultPath: string = {
  let home = switch Null.toOption(homeEnv) {
  | Some(h) => h
  | None => ""
  }
  `${home}/.config/elm-peek/repos.json`
}

// Parses the JSON map. Any failure (missing file, unreadable, malformed
// JSON, wrong shape) is non-fatal: we log to stderr and return None for
// every repo. That mirrors the spec's "explicit map" stance — if the user
// hasn't configured a repo, the only legitimate response is `repo-not-mapped`.
let loadMap = (configPath: string): option<dict<string>> =>
  if !existsSync(configPath) {
    None
  } else {
    switch readFileSync(configPath, "utf8") {
    | contents =>
      switch JSON.parseOrThrow(contents) {
      | JSON.Object(d) =>
        // Validate that every value is a string. Anything else means the
        // user's config is broken — treat the whole file as empty rather
        // than half-honoring it.
        let allStrings = d->Dict.toArray->Array.every(((_k, v)) =>
          switch v {
          | JSON.String(_) => true
          | _ => false
          }
        )
        if allStrings {
          let pathMap = Dict.make()
          d
          ->Dict.toArray
          ->Array.forEach(((k, v)) =>
            switch v {
            | JSON.String(s) => pathMap->Dict.set(k, s)
            | _ => ()
            }
          )
          Some(pathMap)
        } else {
          Console.error(`[elm-peek] ${configPath}: values must be strings`)
          None
        }
      | _ =>
        Console.error(`[elm-peek] ${configPath}: top-level JSON must be an object`)
        None
      | exception _ =>
        Console.error(`[elm-peek] ${configPath}: malformed JSON, ignoring`)
        None
      }
    | exception _ =>
      Console.error(`[elm-peek] ${configPath}: failed to read, ignoring`)
      None
    }
  }

let lookup = (~configPath: string=defaultPath, ~repo: string): option<string> =>
  switch loadMap(configPath) {
  | None => None
  | Some(m) => m->Dict.get(repo)
  }

// Logging-only handler. Slice 1 has no cache to clear, so this is just a
// breadcrumb that the signal arrived. Wired only when the user calls it
// (Server.res opts in at boot) so importing this module from tests doesn't
// register a global signal handler.
let onSighup = (handler: unit => unit): unit => onSignal("SIGHUP", handler)
