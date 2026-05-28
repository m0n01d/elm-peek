// Direct file scan for variant-constructor lookup. elmq's `grep --definitions`
// matches against declaration *header* lines (like `type Foo =`), not the
// variant lines inside the body. So clicking on `| SaveToken` inside
// `type Msg = SaveToken | …` returns nothing from elmq, even with `-F`.
//
// This module reads the file the extension hinted at, walks top-level
// type declarations, and returns the enclosing type whose body contains
// the symbol as a variant constructor.
//
// Used as the last fallback in Elmq.lookup when both the wide and file-
// scoped elmq passes return empty and the extension provided a `file=` hint.

@module("node:fs") external readFileSync: (string, string) => string = "readFileSync"
@module("node:path") external pathJoin: (string, string) => string = "join"

// --- Module-name derivation ---------------------------------------------
//
// We strip the most common Elm source prefixes (src/elm/, src/) and convert
// `/` → `.`. Not perfect — a non-standard source-directories layout would
// produce a slightly wrong module name — but the tooltip header is for
// readability, not strict correctness, and the rest of the response is
// still useful.

let deriveModule = (filePath: string): string => {
  let noExt = if String.endsWith(filePath, ".elm") {
    String.slice(filePath, ~start=0, ~end=String.length(filePath) - 4)
  } else {
    filePath
  }
  let stripped = if String.startsWith(noExt, "src/elm/") {
    String.slice(noExt, ~start=8, ~end=String.length(noExt))
  } else if String.startsWith(noExt, "src/") {
    String.slice(noExt, ~start=4, ~end=String.length(noExt))
  } else {
    noExt
  }
  String.replaceAll(stripped, "/", ".")
}

// --- Scan ---------------------------------------------------------------

// A line "continues" a type declaration if it's empty or starts with
// whitespace. The first non-empty, non-indented line is the start of the
// next top-level declaration.
let isBodyContinuation = (line: string): bool =>
  String.length(line) === 0 ||
  String.startsWith(line, " ") ||
  String.startsWith(line, "\t")

let typeHeaderRe = RegExp.fromString("^type(?:\\s+alias)?\\s+([A-Z]\\w*)")

// Look for the symbol as a variant in any top-level `type` (or
// `type alias`) declaration. Returns the parent type's record, with
// `symbol` set to the parent type's NAME so the tooltip header reads
// "Module.ParentType" — the source body shows the variant in context.
let scanFileForVariant = (
  ~repoPath: string,
  ~filePath: string,
  ~symbol: string,
): option<Wire.definition> => {
  let absPath = pathJoin(repoPath, filePath)
  let contentOpt = switch readFileSync(absPath, "utf8") {
  | c => Some(c)
  | exception _ => None
  }
  switch contentOpt {
  | None => None
  | Some(content) =>
    let lines = content->String.split("\n")
    let n = Array.length(lines)
    let variantRe = RegExp.fromString(`[=|]\\s*${symbol}\\b`)
    let result = ref(None)
    let i = ref(0)
    while result.contents === None && i.contents < n {
      let line = Array.getUnsafe(lines, i.contents)
      switch RegExp.exec(typeHeaderRe, line) {
      | Some(m) =>
        let groups = RegExp.Result.matches(m)
        let typeName = switch groups->Array.get(0) {
        | Some(Some(name)) => name
        | _ => ""
        }
        let startLine = i.contents
        let j = ref(i.contents + 1)
        let endIdx = ref(-1)
        while j.contents < n && endIdx.contents === -1 {
          let l = Array.getUnsafe(lines, j.contents)
          if !isBodyContinuation(l) {
            endIdx := j.contents
          } else {
            j := j.contents + 1
          }
        }
        let endLine = endIdx.contents === -1 ? n : endIdx.contents
        let body =
          lines
          ->Array.slice(~start=startLine, ~end=endLine)
          ->Array.join("\n")
          ->String.trimEnd
        if RegExp.test(variantRe, body) {
          // Locate the variant's own line within the type body so the tooltip
          // link jumps to the constructor, not the type's header (which can
          // be 10+ lines above for long custom types).
          let bodyLines = body->String.split("\n")
          let variantOffset = ref(None)
          let k = ref(0)
          while k.contents < Array.length(bodyLines) && variantOffset.contents === None {
            if RegExp.test(variantRe, Array.getUnsafe(bodyLines, k.contents)) {
              variantOffset := Some(k.contents)
            }
            k := k.contents + 1
          }
          let variantLine = switch variantOffset.contents {
          | Some(offset) => startLine + offset + 1
          | None => startLine + 1
          }
          result := Some({
            Wire.symbol: typeName,
            module_: deriveModule(filePath),
            file: filePath,
            line: variantLine,
            source: body,
          })
        }
        i := endLine
      | None => i := i.contents + 1
      }
    }
    result.contents
  }
}
