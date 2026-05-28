// Integration tests for the local HTTP server. Each test boots Bun.serve on
// an ephemeral port, fetches against it, asserts the response shape, and
// stops the server. Avoids collisions with anyone running on 42069 and lets
// tests run in parallel.
//
// Convention: companion Server.test.mjs shim imports this file's compiled
// output so bun:test discovers it.

@module("bun:test") external describe: (string, unit => unit) => unit = "describe"
@module("bun:test")
external testAsync: (string, unit => promise<unit>) => unit = "test"
@module("bun:test") external expect: 'a => 'expectation = "expect"
@send external toEqual: ('expectation, 'a) => unit = "toEqual"
@send external toBe: ('expectation, 'a) => unit = "toBe"

// --- Bindings for the global fetch / Response we use only in tests --------

type fetchResponse
@val external fetch: string => promise<fetchResponse> = "fetch"

type fetchInit = {method: string}
@val external fetchWith: (string, fetchInit) => promise<fetchResponse> = "fetch"

@get external responseStatus: fetchResponse => int = "status"
@send external responseText: fetchResponse => promise<string> = "text"

type headers
@get external responseHeaders: fetchResponse => headers = "headers"
@send external getHeader: (headers, string) => Null.t<string> = "get"

// --- Helpers --------------------------------------------------------------

// All Server tests that hit a mapped repo inject the elmq stub so they don't
// depend on the real binary being installed. The stub ignores its args and
// always cats tests/fixtures/elmq-output.json — Server tests rely on the
// parser+filter narrowing those 3 fixture lines down to symbol-matched
// results, which is the same property ElmqParse_test asserts directly.
let stubElmqBin = "tests/fixtures/elmq-stub.sh"

let bootEphemeral = (): Bun.server =>
  Bun.serve({port: 0, hostname: "127.0.0.1", fetch: Server.handle})

// Variant that pins the repo config to a fixture file so we can exercise
// the RepoNotMapped / mapped-repo branches without touching ~/.config/...
let bootEphemeralWithConfig = (configPath: string): Bun.server =>
  Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch: Server.makeHandler(~configPath, ~elmqBin=stubElmqBin),
  })

let urlFor = (s: Bun.server, path: string): string =>
  `http://127.0.0.1:${Int.toString(Bun.serverPort(s))}${path}`

// --- Tests ----------------------------------------------------------------

// All happy-path /lookup tests use the fixture repos.json so the response is
// deterministic regardless of the developer's actual ~/.config/elm-peek/.
let fixtureConfig = "tests/fixtures/repos.json"
let fixtureLookup = "/lookup?repo=org/foo&symbol=InstanceStep"

describe("GET /lookup", () => {
  testAsync(
    "returns 200 with Wire.Ok carrying real elmq-parsed definitions (2 InstanceStep)",
    async () => {
      let s = bootEphemeralWithConfig(fixtureConfig)
      let res = await fetch(urlFor(s, fixtureLookup))
      expect(responseStatus(res))->toBe(200)
      let body = await responseText(res)
      Bun.serverStop(s)
      switch Wire.decode(body) {
      | Ok(Wire.Ok({results})) =>
        // Stub returns 3 NDJSON lines (Baz.InstanceStep, Foo.InstanceStepId,
        // Foo.InstanceStep). Server pipeline must filter to decl=="InstanceStep"
        // and surface 2 results.
        expect(Array.length(results))->toBe(2)
        let allMatch = results->Array.every(d => d.Wire.symbol === "InstanceStep")
        expect(allMatch)->toBe(true)
      | Ok(Wire.Err(_)) => assert(false)
      | Error(_) => assert(false)
      }
    },
  )

  testAsync("response includes Access-Control-Allow-Origin: https://github.com", async () => {
    let s = bootEphemeralWithConfig(fixtureConfig)
    let res = await fetch(urlFor(s, fixtureLookup))
    let origin = responseHeaders(res)->getHeader("Access-Control-Allow-Origin")
    Bun.serverStop(s)
    switch Null.toOption(origin) {
    | Some(v) => expect(v)->toBe("https://github.com")
    | None => assert(false)
    }
  })

  testAsync("response includes Content-Type: application/json", async () => {
    let s = bootEphemeralWithConfig(fixtureConfig)
    let res = await fetch(urlFor(s, fixtureLookup))
    let ct = responseHeaders(res)->getHeader("Content-Type")
    Bun.serverStop(s)
    switch Null.toOption(ct) {
    | Some(v) => expect(v)->toBe("application/json")
    | None => assert(false)
    }
  })
})

describe("GET /lookup — bad request envelope", () => {
  testAsync("missing repo → 400 with Wire.Err(BadRequest)", async () => {
    let s = bootEphemeralWithConfig(fixtureConfig)
    let res = await fetch(urlFor(s, "/lookup?symbol=Foo"))
    expect(responseStatus(res))->toBe(400)
    let body = await responseText(res)
    Bun.serverStop(s)
    switch Wire.decode(body) {
    | Ok(Wire.Err({reason: BadRequest, detail: _})) => ()
    | _ => assert(false)
    }
  })

  testAsync("missing symbol → 400 with Wire.Err(BadRequest)", async () => {
    let s = bootEphemeralWithConfig(fixtureConfig)
    let res = await fetch(urlFor(s, "/lookup?repo=org/foo"))
    expect(responseStatus(res))->toBe(400)
    let body = await responseText(res)
    Bun.serverStop(s)
    switch Wire.decode(body) {
    | Ok(Wire.Err({reason: BadRequest, detail: _})) => ()
    | _ => assert(false)
    }
  })

  testAsync("empty repo value → 400 with Wire.Err(BadRequest)", async () => {
    let s = bootEphemeralWithConfig(fixtureConfig)
    let res = await fetch(urlFor(s, "/lookup?repo=&symbol=Foo"))
    expect(responseStatus(res))->toBe(400)
    let body = await responseText(res)
    Bun.serverStop(s)
    switch Wire.decode(body) {
    | Ok(Wire.Err({reason: BadRequest, detail: _})) => ()
    | _ => assert(false)
    }
  })
})

describe("GET /lookup — repo-not-mapped envelope", () => {
  testAsync("unknown repo with fixture config → 404 with Wire.Err(RepoNotMapped)", async () => {
    let s = bootEphemeralWithConfig(fixtureConfig)
    let res = await fetch(urlFor(s, "/lookup?repo=unknown/x&symbol=Foo"))
    expect(responseStatus(res))->toBe(404)
    let body = await responseText(res)
    Bun.serverStop(s)
    switch Wire.decode(body) {
    | Ok(Wire.Err({reason: RepoNotMapped, detail: _})) => ()
    | _ => assert(false)
    }
  })

  testAsync(
    "any repo with nonexistent config file → 404 with Wire.Err(RepoNotMapped)",
    async () => {
      let s = bootEphemeralWithConfig("/nonexistent/repos.json")
      let res = await fetch(urlFor(s, "/lookup?repo=org/foo&symbol=Foo"))
      expect(responseStatus(res))->toBe(404)
      let body = await responseText(res)
      Bun.serverStop(s)
      switch Wire.decode(body) {
      | Ok(Wire.Err({reason: RepoNotMapped, detail: _})) => ()
      | _ => assert(false)
      }
    },
  )
})

describe("GET /lookup — not-found envelope", () => {
  testAsync(
    "mapped repo + symbol with no matching decl → 404 with Wire.Err(NotFound)",
    async () => {
      let s = bootEphemeralWithConfig(fixtureConfig)
      let res = await fetch(urlFor(s, "/lookup?repo=org/foo&symbol=DoesNotExist"))
      expect(responseStatus(res))->toBe(404)
      let body = await responseText(res)
      Bun.serverStop(s)
      switch Wire.decode(body) {
      | Ok(Wire.Err({reason: NotFound, detail: _})) => ()
      | _ => assert(false)
      }
    },
  )
})

describe("GET /lookup — elmq-failed envelope", () => {
  testAsync(
    "mapped repo + missing elmq binary → 500 with Wire.Err(ElmqFailed)",
    async () => {
      let s = Bun.serve({
        port: 0,
        hostname: "127.0.0.1",
        fetch: Server.makeHandler(~configPath=fixtureConfig, ~elmqBin="/nonexistent/elmq-bin"),
      })
      let res = await fetch(urlFor(s, fixtureLookup))
      expect(responseStatus(res))->toBe(500)
      let body = await responseText(res)
      Bun.serverStop(s)
      switch Wire.decode(body) {
      | Ok(Wire.Err({reason: ElmqFailed, detail: _})) => ()
      | _ => assert(false)
      }
    },
  )
})

describe("OPTIONS /lookup (CORS preflight)", () => {
  testAsync("returns 204 with the three CORS headers and no body", async () => {
    let s = bootEphemeral()
    let res = await fetchWith(urlFor(s, "/lookup"), {method: "OPTIONS"})
    let status = responseStatus(res)
    let h = responseHeaders(res)
    let origin = h->getHeader("Access-Control-Allow-Origin")
    let methods = h->getHeader("Access-Control-Allow-Methods")
    let allowHeaders = h->getHeader("Access-Control-Allow-Headers")
    Bun.serverStop(s)
    expect(status)->toBe(204)
    expect(Null.toOption(origin))->toEqual(Some("https://github.com"))
    expect(Null.toOption(methods))->toEqual(Some("GET, OPTIONS"))
    expect(Null.toOption(allowHeaders))->toEqual(Some("Content-Type"))
  })
})

describe("Method/path errors", () => {
  testAsync("PUT /lookup returns 404 with a Wire.Err envelope", async () => {
    let s = bootEphemeral()
    let res = await fetchWith(urlFor(s, "/lookup"), {method: "PUT"})
    expect(responseStatus(res))->toBe(404)
    let body = await responseText(res)
    Bun.serverStop(s)
    switch Wire.decode(body) {
    | Ok(Wire.Err({reason: _, detail: _})) => ()
    | _ => assert(false)
    }
  })

  testAsync("GET /unknown returns 404 with a Wire.Err envelope", async () => {
    let s = bootEphemeral()
    let res = await fetch(urlFor(s, "/unknown"))
    expect(responseStatus(res))->toBe(404)
    let body = await responseText(res)
    Bun.serverStop(s)
    switch Wire.decode(body) {
    | Ok(Wire.Err({reason: _, detail: _})) => ()
    | _ => assert(false)
    }
  })
})
