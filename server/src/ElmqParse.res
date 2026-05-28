// Pure NDJSON → Wire.definition decoder for elmq's `--format json` output.
//
// elmq emits one JSON object per line (NDJSON, NOT a JSON array). We split on
// newlines, parse each line, project the fields we care about, then filter by
// exact `decl == symbol`.
//
// Why filter here:
// SPEC.md says to invoke elmq with `'^<symbol>$'`, but elmq's grep matches
// against the source text of definitions, not the declaration name. The
// fixture's source for `InstanceStep` contains "type alias InstanceStep ="
// which never matches `^InstanceStep$`. The workaround is to invoke elmq with
// `-F <symbol>` (fixed string, substring of source) and filter to exact
// decl-name matches in this parser. See Elmq.lookup for the call site comment.
//
// Field mapping (wire form is dictated by elmq's output):
//   elmq field      → Wire.definition field
//   decl            → symbol
//   module          → module_
//   file            → file
//   start_line      → line (int)
//   source          → source

// --- Field extraction helpers --------------------------------------------

let getString = (d: dict<JSON.t>, key: string): result<string, string> =>
  switch d->Dict.get(key) {
  | Some(JSON.String(s)) => Ok(s)
  | Some(_) => Error(`field "${key}" is not a string`)
  | None => Error(`missing field "${key}"`)
  }

let getInt = (d: dict<JSON.t>, key: string): result<int, string> =>
  switch d->Dict.get(key) {
  | Some(JSON.Number(n)) => Ok(Int.fromFloat(n))
  | Some(_) => Error(`field "${key}" is not a number`)
  | None => Error(`missing field "${key}"`)
  }

// Parse a single NDJSON line into a Wire.definition. The line is already
// trimmed; callers handle blank lines.
let parseLine = (line: string, lineNo: int): result<Wire.definition, string> =>
  switch JSON.parseOrThrow(line) {
  | json =>
    switch json {
    | JSON.Object(d) =>
      switch (
        d->getString("decl"),
        d->getString("module"),
        d->getString("file"),
        d->getInt("start_line"),
        d->getString("source"),
      ) {
      | (Ok(decl), Ok(module_), Ok(file), Ok(line), Ok(source)) =>
        Ok({
          Wire.symbol: decl,
          module_,
          file,
          line,
          source,
        })
      | (Error(e), _, _, _, _)
      | (_, Error(e), _, _, _)
      | (_, _, Error(e), _, _)
      | (_, _, _, Error(e), _)
      | (_, _, _, _, Error(e)) =>
        Error(`malformed line ${Int.toString(lineNo)}: ${e}`)
      }
    | _ => Error(`malformed line ${Int.toString(lineNo)}: not a JSON object`)
    }
  | exception _ => Error(`malformed line ${Int.toString(lineNo)}: invalid JSON`)
  }

// Walk the lines once, accumulating either the first Error or all parsed
// definitions. We carry a 1-based line number for diagnostics.
let parseAllLines = (lines: array<string>): result<array<Wire.definition>, string> => {
  let out: array<Wire.definition> = []
  let err = ref(None)
  let i = ref(0)
  let n = Array.length(lines)
  while err.contents === None && i.contents < n {
    let raw = Array.getUnsafe(lines, i.contents)
    let trimmed = String.trim(raw)
    if trimmed !== "" {
      switch parseLine(trimmed, i.contents + 1) {
      | Ok(def) => Array.push(out, def)
      | Error(e) => err := Some(e)
      }
    }
    i := i.contents + 1
  }
  switch err.contents {
  | Some(e) => Error(e)
  | None => Ok(out)
  }
}

// Variant fallback: when no top-level declaration matches `decl == symbol`,
// look for the symbol as a constructor of a custom type — its source will
// contain `= <symbol>` or `| <symbol>` at a word boundary. Return the parent
// type's records so the tooltip shows the full `type Foo = A | B | <symbol>`
// declaration. TokenScan restricts spans to /^[A-Z][A-Za-z0-9_]*$/ so the
// symbol never contains regex metacharacters.
let variantMatches = (
  all: array<Wire.definition>,
  symbol: string,
): array<Wire.definition> => {
  let re = RegExp.fromString(`[=|]\\s*${symbol}\\b`)
  all->Array.filter(d => re->RegExp.test(d.source))
}

let parseOutput = (~ndjson: string, ~symbol: string): result<array<Wire.definition>, string> => {
  let trimmed = String.trim(ndjson)
  if trimmed === "" {
    Ok([])
  } else {
    switch parseAllLines(String.split(trimmed, "\n")) {
    | Error(e) => Error(e)
    | Ok(all) =>
      let exact = all->Array.filter(d => d.Wire.symbol === symbol)
      if Array.length(exact) > 0 {
        Ok(exact)
      } else {
        Ok(variantMatches(all, symbol))
      }
    }
  }
}
