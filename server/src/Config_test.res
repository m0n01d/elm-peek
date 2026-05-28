// Tests for Config.lookup. Reads JSON from disk on every call (KISS for
// Slice 1 — see Config.res for rationale). Verifies the fixture lookup
// hits, misses, missing file, and malformed JSON all behave correctly
// without crashing.

@module("bun:test") external describe: (string, unit => unit) => unit = "describe"
@module("bun:test") external test: (string, unit => unit) => unit = "test"
@module("bun:test")
external beforeAll: (unit => unit) => unit = "beforeAll"
@module("bun:test")
external afterAll: (unit => unit) => unit = "afterAll"
@module("bun:test") external expect: 'a => 'expectation = "expect"
@send external toEqual: ('expectation, 'a) => unit = "toEqual"
@send external toBe: ('expectation, 'a) => unit = "toBe"

// --- Tiny fs bindings just for setting up the malformed-JSON test --------

@module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@module("node:fs") external unlinkSync: string => unit = "unlinkSync"
@module("node:fs") external existsSync: string => bool = "existsSync"

let malformedPath = "tests/fixtures/.tmp-malformed-repos.json"

describe("Config.lookup — fixture-backed", () => {
  test("returns the mapped path for a known repo", () => {
    let got = Config.lookup(~configPath="tests/fixtures/repos.json", ~repo="org/foo")
    expect(got)->toEqual(Some("tests/fixtures/elm"))
  })

  test("returns None for an unknown repo", () => {
    let got = Config.lookup(~configPath="tests/fixtures/repos.json", ~repo="unknown/x")
    expect(got)->toEqual(None)
  })

  test("returns None when the config file does not exist (no crash)", () => {
    let got = Config.lookup(~configPath="/nonexistent/elm-peek/repos.json", ~repo="any/thing")
    expect(got)->toEqual(None)
  })
})

describe("Config.lookup — malformed JSON", () => {
  beforeAll(() => {
    writeFileSync(malformedPath, "{ this is not valid json")
  })
  afterAll(() => {
    if existsSync(malformedPath) {
      unlinkSync(malformedPath)
    }
  })

  test("returns None and does not crash", () => {
    let got = Config.lookup(~configPath=malformedPath, ~repo="any/thing")
    expect(got)->toEqual(None)
  })
})
