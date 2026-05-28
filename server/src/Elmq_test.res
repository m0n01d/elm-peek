// Tests for Elmq.lookup. Spawns the elmq stub (tests/fixtures/elmq-stub.sh)
// so unit tests are deterministic regardless of whether the real elmq binary
// is on $PATH. A separate smoke test runs the real binary against the sample
// Elm fixture repo, gated on the ELMQ_SMOKE=1 environment variable.
//
// The stub ignores its arguments and always cats tests/fixtures/elmq-output.json
// (3 NDJSON lines: Baz.InstanceStep, Foo.InstanceStepId, Foo.InstanceStep).
// Filtering by `decl == symbol` is what reduces those 3 lines to 2 results for
// symbol=InstanceStep.

@module("bun:test") external describe: (string, unit => unit) => unit = "describe"
@module("bun:test")
external testAsync: (string, unit => promise<unit>) => unit = "test"
@module("bun:test") external expect: 'a => 'expectation = "expect"
@send external toEqual: ('expectation, 'a) => unit = "toEqual"
@send external toBe: ('expectation, 'a) => unit = "toBe"

// --- process.env binding for the smoke gate -------------------------------

@scope(("process", "env")) @val external elmqSmoke: Null.t<string> = "ELMQ_SMOKE"

let stubBin = "tests/fixtures/elmq-stub.sh"

describe("Elmq.lookup — stub binary", () => {
  testAsync("symbol=InstanceStep → Ok with 2 results (Baz + Foo), no InstanceStepId", async () => {
    // repoPath must be a real directory (Bun.spawnSync's cwd needs to exist),
    // but its contents don't matter — the stub ignores args and cats the
    // canned NDJSON. Project root is a convenient real directory.
    let result = await Elmq.lookup(~repoPath=".", ~symbol="InstanceStep", ~elmqBin=stubBin)
    switch result {
    | Ok(defs) =>
      expect(Array.length(defs))->toBe(2)
      let modules = defs->Array.map(d => d.Wire.module_)
      expect(modules->Array.includes("Baz"))->toBe(true)
      expect(modules->Array.includes("Foo"))->toBe(true)
      let allMatch = defs->Array.every(d => d.Wire.symbol === "InstanceStep")
      expect(allMatch)->toBe(true)
    | Error(_) => assert(false)
    }
  })

  testAsync("symbol=DoesNotExist → Ok([]) (parser filters everything out)", async () => {
    let result = await Elmq.lookup(~repoPath=".", ~symbol="DoesNotExist", ~elmqBin=stubBin)
    switch result {
    | Ok(defs) => expect(Array.length(defs))->toBe(0)
    | Error(_) => assert(false)
    }
  })
})

describe("Elmq.lookup — failure modes", () => {
  testAsync("nonexistent binary → Error(ElmqFailed)", async () => {
    let result = await Elmq.lookup(
      ~repoPath=".",
      ~symbol="X",
      ~elmqBin="/nonexistent/elmq-binary-9f3a",
    )
    switch result {
    | Error(Wire.ElmqFailed) => ()
    | _ => assert(false)
    }
  })
})

// --- Smoke test gated on ELMQ_SMOKE=1 ------------------------------------
//
// Skipped by default so CI/local runs don't depend on the real binary. To
// exercise the real elmq → ElmqParse pipeline end-to-end, run:
//   ELMQ_SMOKE=1 bun test

let smokeOn = switch Null.toOption(elmqSmoke) {
| Some("1") => true
| _ => false
}

if smokeOn {
  describe("Elmq.lookup — smoke (real elmq binary)", () => {
    testAsync("InstanceStep against tests/fixtures/elm/ → ≥1 result", async () => {
      let result = await Elmq.lookup(~repoPath="tests/fixtures/elm/", ~symbol="InstanceStep")
      switch result {
      | Ok(defs) => expect(Array.length(defs) >= 1)->toBe(true)
      | Error(_) => assert(false)
      }
    })

    testAsync("NoSuchSymbolXYZ123 against fixture → Ok([])", async () => {
      let result = await Elmq.lookup(~repoPath="tests/fixtures/elm/", ~symbol="NoSuchSymbolXYZ123")
      switch result {
      | Ok(defs) => expect(Array.length(defs))->toBe(0)
      | Error(_) => assert(false)
      }
    })
  })
}
