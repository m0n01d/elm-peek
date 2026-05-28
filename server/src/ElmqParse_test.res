// Tests for ElmqParse.parseOutput — pure NDJSON → Wire.definition decoder.
//
// elmq's `--format json` emits NDJSON (one JSON object per line), and its grep
// matches against source text (not the declaration name). So a `-F InstanceStep`
// search returns a superset that includes `InstanceStepId` because the latter's
// source contains the substring "InstanceStep". The parser filters by
// `decl == symbol` to get exact-symbol-name matches.
//
// Fixture: tests/fixtures/elmq-output.json contains 3 NDJSON lines:
//   Baz.InstanceStep, Foo.InstanceStepId, Foo.InstanceStep.
// Filtering by symbol="InstanceStep" should yield exactly 2 results.

@module("bun:test") external describe: (string, unit => unit) => unit = "describe"
@module("bun:test") external test: (string, unit => unit) => unit = "test"
@module("bun:test") external expect: 'a => 'expectation = "expect"
@send external toEqual: ('expectation, 'a) => unit = "toEqual"
@send external toBe: ('expectation, 'a) => unit = "toBe"

// --- fs binding for reading the fixture (Config.res uses the same pattern) ---

@module("node:fs") external readFileSync: (string, string) => string = "readFileSync"

let fixturePath = "tests/fixtures/elmq-output.json"

describe("ElmqParse.parseOutput — fixture", () => {
  test("symbol=InstanceStep → exactly 2 results (Baz + Foo), no InstanceStepId", () => {
    let ndjson = readFileSync(fixturePath, "utf8")
    switch ElmqParse.parseOutput(~ndjson, ~symbol="InstanceStep") {
    | Ok(defs) =>
      expect(Array.length(defs))->toBe(2)
      // All `decl` values are "InstanceStep" — never "InstanceStepId".
      let allSymbolsMatch = defs->Array.every(d => d.Wire.symbol === "InstanceStep")
      expect(allSymbolsMatch)->toBe(true)
      // Modules present in the filtered set.
      let modules = defs->Array.map(d => d.Wire.module_)
      expect(modules->Array.includes("Baz"))->toBe(true)
      expect(modules->Array.includes("Foo"))->toBe(true)
    | Error(e) =>
      Console.error(`parseOutput unexpectedly returned Error: ${e}`)
      assert(false)
    }
  })

  test("field mapping: decl→symbol, module→module_, start_line→line", () => {
    let ndjson = readFileSync(fixturePath, "utf8")
    switch ElmqParse.parseOutput(~ndjson, ~symbol="InstanceStep") {
    | Ok(defs) =>
      // Find the Baz one (start_line=7 in the fixture).
      let baz = defs->Array.find(d => d.Wire.module_ === "Baz")
      switch baz {
      | Some(d) =>
        expect(d.Wire.symbol)->toBe("InstanceStep")
        expect(d.Wire.module_)->toBe("Baz")
        expect(d.Wire.file)->toBe("tests/fixtures/elm/src/Baz.elm")
        expect(d.Wire.line)->toBe(7)
        expect(d.Wire.source)->toBe("type alias InstanceStep =\n    { kind : String }")
      | None => assert(false)
      }
    | Error(_) => assert(false)
    }
  })

  test("symbol=NonExistent → empty array", () => {
    let ndjson = readFileSync(fixturePath, "utf8")
    switch ElmqParse.parseOutput(~ndjson, ~symbol="NonExistent") {
    | Ok(defs) => expect(Array.length(defs))->toBe(0)
    | Error(_) => assert(false)
    }
  })

  test("symbol=InstanceStepId → exactly 1 result (only the Foo alias)", () => {
    let ndjson = readFileSync(fixturePath, "utf8")
    switch ElmqParse.parseOutput(~ndjson, ~symbol="InstanceStepId") {
    | Ok(defs) =>
      expect(Array.length(defs))->toBe(1)
      switch defs->Array.get(0) {
      | Some(d) =>
        expect(d.Wire.symbol)->toBe("InstanceStepId")
        expect(d.Wire.module_)->toBe("Foo")
      | None => assert(false)
      }
    | Error(_) => assert(false)
    }
  })
})

describe("ElmqParse.parseOutput — degenerate inputs", () => {
  test("empty string → Ok([])", () => {
    switch ElmqParse.parseOutput(~ndjson="", ~symbol="X") {
    | Ok(defs) => expect(Array.length(defs))->toBe(0)
    | Error(_) => assert(false)
    }
  })

  test("whitespace-only → Ok([])", () => {
    switch ElmqParse.parseOutput(~ndjson="   \n\n  \n", ~symbol="X") {
    | Ok(defs) => expect(Array.length(defs))->toBe(0)
    | Error(_) => assert(false)
    }
  })

  test("blank lines between records are skipped", () => {
    let ndjson =
      `{"decl":"X","decl_kind":"type_alias","start_line":1,"end_line":2,"file":"f.elm","module":"M","source":"type alias X = Int"}\n\n` ++
      `{"decl":"X","decl_kind":"type_alias","start_line":3,"end_line":4,"file":"g.elm","module":"N","source":"type alias X = String"}\n`
    switch ElmqParse.parseOutput(~ndjson, ~symbol="X") {
    | Ok(defs) => expect(Array.length(defs))->toBe(2)
    | Error(_) => assert(false)
    }
  })
})

describe("ElmqParse.parseOutput — malformed", () => {
  test("a non-JSON line → Error(_)", () => {
    let ndjson =
      `not json at all\n` ++
      `{"decl":"X","decl_kind":"type_alias","start_line":1,"end_line":2,"file":"f.elm","module":"M","source":"s"}\n`
    switch ElmqParse.parseOutput(~ndjson, ~symbol="X") {
    | Error(_) => ()
    | Ok(_) => assert(false)
    }
  })

  test("missing required field (module) → Error(_)", () => {
    let ndjson = `{"decl":"X","decl_kind":"type_alias","start_line":1,"end_line":2,"file":"f.elm","source":"s"}\n`
    switch ElmqParse.parseOutput(~ndjson, ~symbol="X") {
    | Error(_) => ()
    | Ok(_) => assert(false)
    }
  })

  test("wrong-typed field (start_line as string) → Error(_)", () => {
    let ndjson = `{"decl":"X","decl_kind":"type_alias","start_line":"oops","end_line":2,"file":"f.elm","module":"M","source":"s"}\n`
    switch ElmqParse.parseOutput(~ndjson, ~symbol="X") {
    | Error(_) => ()
    | Ok(_) => assert(false)
    }
  })
})

describe("ElmqParse.parseOutput — variant fallback", () => {
  test("symbol is a variant of a custom type → returns parent type's record", () => {
    let parent =
      `{"decl":"Subtree","decl_kind":"custom_type","start_line":1,"end_line":5,` ++
      `"file":"src/Tree.elm","module":"Tree","match_count":1,` ++
      `"source":"type Subtree\\n    = Leaf\\n    | SubtreeData String\\n    | Branch (List Subtree)"}`
    switch ElmqParse.parseOutput(~ndjson=parent, ~symbol="SubtreeData") {
    | Ok([def]) =>
      // Parent type record returned; tooltip header shows "Tree.Subtree" but
      // the source body reveals SubtreeData as one of the variants.
      expect(def.Wire.symbol)->toBe("Subtree")
      expect(def.Wire.module_)->toBe("Tree")
      expect(def.Wire.source->String.includes("SubtreeData"))->toBe(true)
    | _ => assert(false)
    }
  })

  test("exact match wins over variant fallback", () => {
    let ndjson =
      `{"decl":"Foo","decl_kind":"type_alias","start_line":1,"end_line":2,` ++
      `"file":"src/A.elm","module":"A","match_count":1,"source":"type alias Foo = Int"}\n` ++
      `{"decl":"Bar","decl_kind":"custom_type","start_line":3,"end_line":5,` ++
      `"file":"src/B.elm","module":"B","match_count":1,"source":"type Bar = Foo | Baz"}`
    switch ElmqParse.parseOutput(~ndjson, ~symbol="Foo") {
    | Ok([def]) =>
      expect(def.Wire.symbol)->toBe("Foo")
      expect(def.Wire.module_)->toBe("A")
    | _ => assert(false)
    }
  })

  test("no exact and no variant match → empty array", () => {
    let ndjson =
      `{"decl":"Other","decl_kind":"type_alias","start_line":1,"end_line":2,` ++
      `"file":"f.elm","module":"M","match_count":1,"source":"type alias Other = Int"}`
    switch ElmqParse.parseOutput(~ndjson, ~symbol="Nothing") {
    | Ok([]) => ()
    | _ => assert(false)
    }
  })

  test("variant with `|` prefix on its own line", () => {
    let parent =
      `{"decl":"Color","decl_kind":"custom_type","start_line":1,"end_line":4,` ++
      `"file":"src/Color.elm","module":"Color","match_count":1,` ++
      `"source":"type Color\\n    = Red\\n    | Green\\n    | Blue"}`
    switch ElmqParse.parseOutput(~ndjson=parent, ~symbol="Green") {
    | Ok([def]) => expect(def.Wire.symbol)->toBe("Color")
    | _ => assert(false)
    }
  })
})
