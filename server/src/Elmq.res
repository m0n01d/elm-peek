// Thin wrapper around the elmq CLI.
//
// Spawns:
//   <elmqBin> grep --definitions --source --format json -F <symbol> <repoPath>
//
// Why `-F <symbol>` instead of `'^<symbol>$'` (which SPEC.md says to use):
// elmq's grep matches against the source text of each definition, not the
// declaration name. The source for `InstanceStep` reads
//     "type alias InstanceStep =\n    { ... }"
// so a `^InstanceStep$` anchor never matches. With `-F <symbol>` we get a
// SUPERSET (any definition whose source text contains the symbol as a
// substring — `InstanceStepId` comes back when searching `InstanceStep`),
// and `ElmqParse.parseOutput` filters down to exact `decl == symbol` matches.
// Don't "fix" this back to the regex form without re-reading SPEC vs. real
// elmq behavior.
//
// Exit-code contract (observed against real elmq):
//   0 → matches printed to stdout. Parse and return Ok.
//   1 + empty stdout + empty stderr → no matches (typical grep "no results").
//                                     Return Ok([]). Caller decides NotFound.
//   anything else → ElmqFailed.
//
// Binary missing / posix_spawn ENOENT → spawnSync throws JS exception →
// ElmqFailed.
//
// Tests inject ~elmqBin pointing at tests/fixtures/elmq-stub.sh; the default
// is the bare "elmq" name (PATH resolution).

let defaultBin = "elmq"

@module("node:path") external pathResolve: string => string = "resolve"

// Relative elmqBin paths (e.g. tests/fixtures/elmq-stub.sh) must be turned
// into absolutes before spawn, because we set cwd=repoPath below. Bare names
// like "elmq" pass through unchanged so $PATH lookup still resolves them.
let resolveBin = (bin: string): string =>
  if String.startsWith(bin, "/") {
    bin
  } else if String.includes(bin, "/") {
    pathResolve(bin)
  } else {
    bin
  }

// One spawn of elmq scoped to `searchPath` (".") or a single file path.
let runOne = (
  ~repoPath: string,
  ~symbol: string,
  ~elmqBin: string,
  ~searchPath: string,
): result<array<Wire.definition>, Wire.errorReason> => {
  let cmd = [resolveBin(elmqBin), "grep", "--definitions", "--source", "--format", "json", "-F", symbol, searchPath]
  switch Bun.spawnSync({cmd, cwd: repoPath}) {
  | exception _ =>
    Console.error(`[elm-peek] failed to spawn ${elmqBin} (binary missing or not executable)`)
    Error(Wire.ElmqFailed)
  | r =>
    let stdout = Bun.bufferToString(r.stdout)
    let stderr = Bun.bufferToString(r.stderr)
    let stdoutTrim = String.trim(stdout)
    let stderrTrim = String.trim(stderr)
    switch (r.exitCode, stdoutTrim, stderrTrim) {
    // grep convention: exit 1 with no output = no matches.
    | (1, "", "") => Ok([])
    | (0, _, _) =>
      switch ElmqParse.parseOutput(~ndjson=stdout, ~symbol) {
      | Ok(defs) => Ok(defs)
      | Error(e) =>
        Console.error(`[elm-peek] elmq output parse error: ${e}`)
        Error(Wire.ElmqFailed)
      }
    | (code, _, _) =>
      // Some elmq exits (e.g. parse errors in one file) are non-fatal at the
      // repo level — there can be results on stdout regardless. We still
      // surface as ElmqFailed for non-zero with empty output; if there IS
      // output, try to parse it.
      let detail = if stderrTrim !== "" {
        stderrTrim
      } else {
        stdoutTrim
      }
      Console.error(
        `[elm-peek] elmq exited with code ${Int.toString(code)}: ${detail}`,
      )
      Error(Wire.ElmqFailed)
    }
  }
}

let lookup = (
  ~repoPath: string,
  ~symbol: string,
  ~elmqBin: string=defaultBin,
  ~file: option<string>=?,
  ~module_: option<string>=?,
): promise<result<array<Wire.definition>, Wire.errorReason>> => {
  // Three-pass strategy:
  //   1. Whole-repo elmq grep ('.') — catches imported / exposed top-level
  //      decls defined anywhere in the project. Right answer for most clicks.
  //   2. File-scoped elmq grep — catches module-local top-level decls that
  //      elmq's wide grep can't reach (e.g. when the wide pass returns 0).
  //   3. Direct file scan (LocalScan.scanFileForVariant) — catches variant
  //      constructors. elmq's `--definitions` mode only matches against
  //      declaration *header* lines (`type Foo =`), not the `| Variant`
  //      lines inside the body. The direct scan walks top-level types in
  //      the hinted file and returns the enclosing parent type when the
  //      symbol appears as a variant.
  //
  // Differentiates local-vs-imported automatically: imported types resolve
  // in pass 1; local top-level decls in pass 2; local variants in pass 3.
  let wide = runOne(~repoPath, ~symbol, ~elmqBin, ~searchPath=".")
  let afterFile = switch (wide, file) {
  | (Ok([]), Some(f)) => runOne(~repoPath, ~symbol, ~elmqBin, ~searchPath=f)
  | _ => wide
  }
  let final = switch (afterFile, file) {
  | (Ok([]), Some(filePath)) =>
    switch LocalScan.scanFileForVariant(~repoPath, ~filePath, ~symbol) {
    | Some(def) => Ok([def])
    | None => Ok([])
    }
  | _ => afterFile
  }
  // Module-aware refinement:
  //   1. Resolve the module prefix (if any) to its canonical module name
  //      via the hinted file's import alias map.
  //   2. If we have a canonical module AND the existing results don't
  //      include a match in that module, derive the module's likely file
  //      path and run LocalScan + a file-scoped elmq there. elmq's wide
  //      grep misses `type Foo = | Client | …` when the body is multi-
  //      line, so this targeted pass fills the gap. Hits get prepended.
  //   3. Disambiguation order: module match wins, otherwise file match
  //      wins, otherwise leave order alone.
  let resolvedModule = switch (module_, file) {
  | (Some(prefix), Some(filePath)) =>
    switch Imports.resolveAlias(~repoPath, ~filePath, ~prefix) {
    | Some(real) => Some(real)
    | None => Some(prefix) // not aliased; treat prefix as literal module name
    }
  | _ => None
  }
  let candidatePathsForModule = (modName: string): array<string> => {
    let fragments = String.replaceAll(modName, ".", "/")
    [`src/elm/${fragments}.elm`, `src/${fragments}.elm`]
  }
  let scanModuleFile = (modName: string): array<Wire.definition> => {
    let candidates = candidatePathsForModule(modName)
    let hits = ref([])
    candidates->Array.forEach(filePath =>
      if Array.length(hits.contents) === 0 {
        switch LocalScan.scanFileForVariant(~repoPath, ~filePath, ~symbol) {
        | Some(def) => hits := [def]
        | None =>
          switch runOne(~repoPath, ~symbol, ~elmqBin, ~searchPath=filePath) {
          | Ok(defs) if Array.length(defs) > 0 => hits := defs
          | _ => ()
          }
        }
      }
    )
    hits.contents
  }
  let withModule = switch (resolvedModule, final) {
  | (Some(realModule), Ok(existing)) =>
    let alreadyMatched = existing->Array.some(d => d.Wire.module_ === realModule)
    if alreadyMatched {
      Ok(existing)
    } else {
      let extras = scanModuleFile(realModule)
      Array.length(extras) > 0 ? Ok(Array.concat(extras, existing)) : Ok(existing)
    }
  | _ => final
  }
  let prioritized = switch (withModule, resolvedModule, file) {
  | (Ok(results), Some(mod_), _) if Array.length(results) > 1 =>
    let inModule = results->Array.filter(d => d.Wire.module_ === mod_)
    let elsewhere = results->Array.filter(d => d.Wire.module_ !== mod_)
    Ok(Array.concat(inModule, elsewhere))
  | (Ok(results), None, Some(filePath)) if Array.length(results) > 1 =>
    let inFile = results->Array.filter(d => d.Wire.file === filePath)
    let elsewhere = results->Array.filter(d => d.Wire.file !== filePath)
    Ok(Array.concat(inFile, elsewhere))
  | _ => withModule
  }
  Promise.resolve(prioritized)
}
