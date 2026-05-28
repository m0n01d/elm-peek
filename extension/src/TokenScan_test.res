// Tests for TokenScan — pure DOM walker that finds capitalized identifier
// spans on GitHub blob/diff pages, deduplicated via WeakSet.
//
// Per SPEC §"Token detection (extension)": filter <span> by textContent
// matching /^[A-Z][A-Za-z0-9_]*$/, skip anything inside .pl-s (string) or
// .pl-c (comment) ancestors, and don't re-bind across mutations.

@module("bun:test") external describe: (string, unit => unit) => unit = "describe"
@module("bun:test") external test: (string, unit => unit) => unit = "test"
@module("bun:test") external beforeAll: (unit => unit) => unit = "beforeAll"
@module("bun:test") external beforeEach: (unit => unit) => unit = "beforeEach"
@module("bun:test") external expect: 'a => 'expectation = "expect"
@send external toEqual: ('expectation, 'a) => unit = "toEqual"
@send external toBe: ('expectation, 'a) => unit = "toBe"

// --- happy-dom registration ----------------------------------------------
//
// `GlobalRegistrator` is a class with static methods + a static getter
// `isRegistered`. Bind via @scope on the class name. `isRegistered` is a
// getter, so it has no call parens — use a `unit => bool` thunk that calls
// out to a tiny JS helper... actually, the simpler path is to just always
// guard with a try/catch around register, since a double-register throws.

type registerOpts = {url: string}
@module("@happy-dom/global-registrator") @scope("GlobalRegistrator")
external register: registerOpts => unit = "register"

// --- Globals exposed by happy-dom once registered ------------------------

@val external document: Dom.document = "document"

@get external documentBody: Dom.document => Dom.element = "body"
@set external setInnerHTML: (Dom.element, string) => unit = "innerHTML"
@get external textContent: Dom.element => string = "textContent"

// --- File reading --------------------------------------------------------

@module("node:fs") external readFileSync: (string, string) => string = "readFileSync"

let readFixture = (path: string): string => readFileSync(path, "utf8")

// --- Test setup ----------------------------------------------------------

// Happy-dom throws if registered twice — swallow that specific failure so
// multiple test files can each call `register` in their own beforeAll.
let safeRegister = (): unit =>
  try register({url: "https://github.com/"}) catch {
  | _ => ()
  }

beforeAll(() => {
  safeRegister()
})

beforeEach(() => {
  TokenScan.resetSeen()
  // Reset between tests so each suite starts from a clean DOM.
  documentBody(document)->setInnerHTML("")
})

// Map element array → sorted unique text-content list for stable assertions.
let texts = (els: array<Dom.element>): array<string> => {
  let arr = els->Array.map(textContent)
  arr->Array.toSorted(String.compare)
}

// --- isCandidateText -----------------------------------------------------

describe("TokenScan.isCandidateText", () => {
  test("accepts capitalized identifiers", () => {
    expect(TokenScan.isCandidateText("Foo"))->toBe(true)
    expect(TokenScan.isCandidateText("InstanceStep"))->toBe(true)
    expect(TokenScan.isCandidateText("Foo123"))->toBe(true)
    expect(TokenScan.isCandidateText("X"))->toBe(true)
    expect(TokenScan.isCandidateText("Foo_Bar"))->toBe(true)
  })

  test("rejects lowercase-leading identifiers", () => {
    expect(TokenScan.isCandidateText("foo"))->toBe(false)
    expect(TokenScan.isCandidateText("lowercaseStart"))->toBe(false)
  })

  test("rejects snake_case and empty", () => {
    expect(TokenScan.isCandidateText("snake_case"))->toBe(false)
    expect(TokenScan.isCandidateText(""))->toBe(false)
  })

  test("rejects punctuation-only and whitespace", () => {
    expect(TokenScan.isCandidateText("= "))->toBe(false)
    expect(TokenScan.isCandidateText("123"))->toBe(false)
    expect(TokenScan.isCandidateText("Foo-Bar"))->toBe(false)
  })
})

// --- findCandidateSpans on github-blob.html ------------------------------

describe("TokenScan.findCandidateSpans — github-blob fixture", () => {
  let loadFixture = () => {
    let html = readFixture("tests/fixtures/github-blob.html")
    documentBody(document)->setInnerHTML(html)
  }

  test("returns the expected capitalized identifiers, skipping decoys", () => {
    loadFixture()
    let found = TokenScan.findCandidateSpans(document)
    // Expected (sorted): Bool, InstanceStep, InstanceStepId, String, True
    expect(found->texts)->toEqual(["Bool", "InstanceStep", "InstanceStepId", "String", "True"])
  })

  test("returns empty on a second call (WeakSet dedup)", () => {
    loadFixture()
    let _ = TokenScan.findCandidateSpans(document)
    let again = TokenScan.findCandidateSpans(document)
    expect(again->Array.length)->toBe(0)
  })

  test("resetSeen lets the same spans be returned again", () => {
    loadFixture()
    let first = TokenScan.findCandidateSpans(document)
    TokenScan.resetSeen()
    let second = TokenScan.findCandidateSpans(document)
    expect(first->texts)->toEqual(second->texts)
  })

  test("does not include words inside .pl-s strings or .pl-c comments", () => {
    loadFixture()
    let found = TokenScan.findCandidateSpans(document)
    let names = found->texts
    expect(names->Array.includes("Hello"))->toBe(false)
    expect(names->Array.includes("TODO"))->toBe(false)
  })
})

// --- findCandidateSpans on github-pr-diff.html ---------------------------

describe("TokenScan.findCandidateSpans — github-pr-diff fixture", () => {
  let loadFixture = () => {
    let html = readFixture("tests/fixtures/github-pr-diff.html")
    documentBody(document)->setInnerHTML(html)
  }

  test("returns identifiers across +/- diff lines", () => {
    loadFixture()
    let found = TokenScan.findCandidateSpans(document)
    // Expected (sorted): InstanceStep, InstanceStepId, Process, Result, String
    // Note: Process appears on both - and + lines; we want both span elements,
    // so dedup is by element-identity, not by text. Sorting all texts gives:
    // ["InstanceStep", "InstanceStepId", "Process", "Process", "Result", "String"]
    expect(found->texts)->toEqual([
      "InstanceStep",
      "InstanceStepId",
      "Process",
      "Process",
      "Result",
      "String",
    ])
  })

  test("skips TODO inside .pl-c and Error inside .pl-s", () => {
    loadFixture()
    let found = TokenScan.findCandidateSpans(document)
    let names = found->texts
    expect(names->Array.includes("TODO"))->toBe(false)
    expect(names->Array.includes("Error"))->toBe(false)
  })
})
