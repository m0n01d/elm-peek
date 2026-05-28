// Parse Elm import statements and resolve module aliases.
//
// Patterns we recognize (per Elm language reference — single-line only):
//   `import Foo.Bar`                            → alias "Bar"  → "Foo.Bar"
//   `import Foo.Bar exposing (Baz)`             → alias "Bar"  → "Foo.Bar"
//   `import Foo.Bar as B`                       → alias "B"    → "Foo.Bar"
//   `import Foo.Bar as B exposing (Baz)`        → alias "B"    → "Foo.Bar"
//
// Used by Elmq.lookup to disambiguate when the user clicks the right side
// of a qualified reference like `B.SomeName` — the extension
// passes `module=B` and we resolve that alias here.

@module("node:fs") external readFileSync: (string, string) => string = "readFileSync"
@module("node:path") external pathJoin: (string, string) => string = "join"

// `^import\s+([A-Z][\w.]*)(?:\s+as\s+([A-Z][\w.]*))?` — first capture is the
// full dotted module path, second is the `as` alias if any.
let importRe = RegExp.fromString("^import\\s+([A-Z][\\w.]*)(?:\\s+as\\s+([A-Z][\\w.]*))?")

// Build a map from the name a user would write in source (alias if present,
// else the last segment of the module path) to the canonical full module
// name (e.g. "Foo.Bar.Baz").
let parseImports = (source: string): dict<string> => {
  let imports = Dict.make()
  let lines = String.split(source, "\n")
  lines->Array.forEach(line => {
    switch RegExp.exec(importRe, line) {
    | Some(m) =>
      let groups = RegExp.Result.matches(m)
      let modulePath = switch groups->Array.get(0) {
      | Some(Some(p)) => p
      | _ => ""
      }
      if modulePath !== "" {
        let aliasOpt = switch groups->Array.get(1) {
        | Some(Some(a)) => Some(a)
        | _ => None
        }
        let key = switch aliasOpt {
        | Some(a) => a
        | None =>
          // No `as` clause — Elm uses the last dotted segment as the implicit
          // qualifier.
          let parts = String.split(modulePath, ".")
          switch parts->Array.get(Array.length(parts) - 1) {
          | Some(last) => last
          | None => modulePath
          }
        }
        imports->Dict.set(key, modulePath)
      }
    | None => ()
    }
  })
  imports
}

// Resolve a user-written module prefix (e.g. "B") to its
// canonical module name (e.g. "Foo.Bar.Baz"). Reads the file
// from disk, parses imports, returns the alias's target — or None if the
// prefix isn't a known alias. Caller can decide whether to fall back to
// treating the prefix as a literal module name.
let resolveAlias = (~repoPath: string, ~filePath: string, ~prefix: string): option<string> => {
  let absPath = pathJoin(repoPath, filePath)
  let contentOpt = switch readFileSync(absPath, "utf8") {
  | c => Some(c)
  | exception _ => None
  }
  switch contentOpt {
  | None => None
  | Some(content) => parseImports(content)->Dict.get(prefix)
  }
}
