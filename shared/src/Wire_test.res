// First red→green test of the project. Exercises Wire encode/decode
// round-trips for every errorReason and a populated Ok envelope.

@module("bun:test") external describe: (string, unit => unit) => unit = "describe"
@module("bun:test") external test: (string, unit => unit) => unit = "test"
@module("bun:test") external expect: 'a => 'expectation = "expect"
@send external toEqual: ('expectation, 'a) => unit = "toEqual"
@send external toBe: ('expectation, 'a) => unit = "toBe"

let sampleDef: Wire.definition = {
  symbol: "InstanceStep",
  module_: "Model.Process.InstanceStep",
  file: "src/Model/Process/InstanceStep.elm",
  line: 42,
  source: "type alias InstanceStep =\n    { id : InstanceStepId }",
}

describe("Wire.encode → Wire.decode round-trip", () => {
  test("Ok with one result", () => {
    let original = Wire.Ok({results: [sampleDef]})
    let encoded = Wire.encode(original)
    let decoded = Wire.decode(encoded)
    expect(decoded)->toEqual(Ok(original))
  })

  test("Ok with multiple results", () => {
    let other: Wire.definition = {...sampleDef, symbol: "OtherType", line: 99}
    let original = Wire.Ok({results: [sampleDef, other]})
    let decoded = Wire.decode(Wire.encode(original))
    expect(decoded)->toEqual(Ok(original))
  })

  test("Ok with empty results", () => {
    let original = Wire.Ok({results: []})
    let decoded = Wire.decode(Wire.encode(original))
    expect(decoded)->toEqual(Ok(original))
  })

  test("Err RepoNotMapped", () => {
    let original = Wire.Err({reason: RepoNotMapped, detail: "org/foo not in repos.json"})
    let decoded = Wire.decode(Wire.encode(original))
    expect(decoded)->toEqual(Ok(original))
  })

  test("Err NotFound", () => {
    let original = Wire.Err({reason: NotFound, detail: "no declaration"})
    let decoded = Wire.decode(Wire.encode(original))
    expect(decoded)->toEqual(Ok(original))
  })

  test("Err ElmqFailed", () => {
    let original = Wire.Err({reason: ElmqFailed, detail: "exit 1"})
    let decoded = Wire.decode(Wire.encode(original))
    expect(decoded)->toEqual(Ok(original))
  })

  test("Err BadRequest", () => {
    let original = Wire.Err({reason: BadRequest, detail: "missing symbol"})
    let decoded = Wire.decode(Wire.encode(original))
    expect(decoded)->toEqual(Ok(original))
  })
})

describe("Wire JSON shape", () => {
  test("Ok envelope has kind=\"ok\" and uses \"module\" (not module_) on the wire", () => {
    let encoded = Wire.encode(Wire.Ok({results: [sampleDef]}))
    let parsed = JSON.parseOrThrow(encoded)
    switch parsed {
    | JSON.Object(d) =>
      switch (d->Dict.get("kind"), d->Dict.get("results")) {
      | (Some(JSON.String("ok")), Some(JSON.Array([JSON.Object(item)]))) =>
        switch item->Dict.get("module") {
        | Some(JSON.String(m)) => expect(m)->toBe("Model.Process.InstanceStep")
        | _ => assert(false)
        }
      | _ => assert(false)
      }
    | _ => assert(false)
    }
  })

  test("Err envelope has kind=\"error\" and kebab-case reason", () => {
    let encoded = Wire.encode(Wire.Err({reason: ElmqFailed, detail: "x"}))
    let parsed = JSON.parseOrThrow(encoded)
    switch parsed {
    | JSON.Object(d) =>
      switch (d->Dict.get("kind"), d->Dict.get("reason")) {
      | (Some(JSON.String("error")), Some(JSON.String(r))) => expect(r)->toBe("elmq-failed")
      | _ => assert(false)
      }
    | _ => assert(false)
    }
  })
})

describe("Wire.decode errors", () => {
  test("invalid JSON", () => {
    switch Wire.decode("not json {") {
    | Error(_) => ()
    | Ok(_) => assert(false)
    }
  })

  test("unknown reason code", () => {
    switch Wire.decode(`{"kind":"error","reason":"nope","detail":"x"}`) {
    | Error(_) => ()
    | Ok(_) => assert(false)
    }
  })
})
