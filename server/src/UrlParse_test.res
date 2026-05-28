// Tests for UrlParse.parse. Exercises both full-URL and path-only forms,
// percent-decoding, optional params, and the BadRequest envelope for
// missing/empty required params.

@module("bun:test") external describe: (string, unit => unit) => unit = "describe"
@module("bun:test") external test: (string, unit => unit) => unit = "test"
@module("bun:test") external expect: 'a => 'expectation = "expect"
@send external toEqual: ('expectation, 'a) => unit = "toEqual"
@send external toBe: ('expectation, 'a) => unit = "toBe"

describe("UrlParse.parse — happy paths", () => {
  test("full URL with percent-encoded slash in repo", () => {
    let parsed = UrlParse.parse(
      "http://127.0.0.1:42069/lookup?repo=org%2Ffoo&symbol=InstanceStep",
    )
    expect(parsed)->toEqual(
      Ok(({repo: "org/foo", symbol: "InstanceStep", module_: None, ref: None, file: None}: UrlParse.query)),
    )
  })

  test("path-only form (no scheme/host)", () => {
    let parsed = UrlParse.parse("/lookup?repo=a/b&symbol=Foo")
    expect(parsed)->toEqual(
      Ok(({repo: "a/b", symbol: "Foo", module_: None, ref: None, file: None}: UrlParse.query)),
    )
  })

  test("optional module and ref present", () => {
    let parsed = UrlParse.parse("/lookup?repo=a/b&symbol=Foo&module=Bar.Baz&ref=main")
    expect(parsed)->toEqual(
      Ok(
        (
          {
            repo: "a/b",
            symbol: "Foo",
            module_: Some("Bar.Baz"),
            ref: Some("main"),
            file: None,
          }: UrlParse.query
        ),
      ),
    )
  })

  test("optional file hint present", () => {
    let parsed = UrlParse.parse(
      "/lookup?repo=a/b&symbol=Foo&file=src/elm/App/Client/Store.elm",
    )
    switch parsed {
    | Ok(q) => expect(q.file)->toEqual(Some("src/elm/App/Client/Store.elm"))
    | Error(_) => assert(false)
    }
  })
})

describe("UrlParse.parse — BadRequest paths", () => {
  test("missing repo", () => {
    expect(UrlParse.parse("/lookup?symbol=Foo"))->toEqual(Error(Wire.BadRequest))
  })

  test("missing symbol", () => {
    expect(UrlParse.parse("/lookup?repo=a/b"))->toEqual(Error(Wire.BadRequest))
  })

  test("empty repo value", () => {
    expect(UrlParse.parse("/lookup?repo=&symbol=Foo"))->toEqual(Error(Wire.BadRequest))
  })

  test("empty symbol value", () => {
    expect(UrlParse.parse("/lookup?repo=a/b&symbol="))->toEqual(Error(Wire.BadRequest))
  })

  test("both missing", () => {
    expect(UrlParse.parse("/lookup"))->toEqual(Error(Wire.BadRequest))
  })
})
