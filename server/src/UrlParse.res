// Parse the `/lookup` query string into a typed `query` record.
//
// Spec: SPEC.md#wire-protocol — `repo` and `symbol` are required; `module`
// and `ref` are optional. The wire field `module` maps to `module_` here
// because `module` is a reserved word in ReScript (same trick as Wire.res).
//
// We use the WHATWG URL global so percent-decoding ("org%2Ffoo" → "org/foo")
// is handled by the runtime instead of by hand-rolled code. `new URL(path)`
// throws on a relative URL, so we always supply a dummy base when the input
// looks like a path-only form. Callers can hand us either a full URL (what
// Bun's `request.url` gives) or a path+query (handy in tests).

// --- Bindings (file-scoped) -----------------------------------------------

type url
type urlSearchParams

@new external makeUrl: string => url = "URL"
@new external makeUrlWithBase: (string, string) => url = "URL"
@get external searchParams: url => urlSearchParams = "searchParams"
@send external paramsGet: (urlSearchParams, string) => Null.t<string> = "get"

// --- Public types ---------------------------------------------------------

type query = {
  repo: string,
  symbol: string,
  module_: option<string>,
  ref: option<string>,
  // Optional file hint from the extension. When present the server narrows
  // elmq's grep to that single file inside the repo — useful for local
  // variants whose parent type is defined in the same module the user is
  // viewing.
  file: option<string>,
}

// --- Helpers --------------------------------------------------------------

// `new URL("/lookup?x=1")` throws (relative URL); `new URL("/lookup?x=1", "http://localhost")`
// is fine. We detect a scheme by looking for "://" — anything else gets a base.
let toUrl = (input: string): result<url, unit> => {
  let hasScheme =
    String.indexOf(input, "://") !== -1 &&
      String.indexOf(input, "://") < (
        switch String.indexOf(input, "?") {
        | -1 => String.length(input)
        | i => i
        }
      )
  try {
    let u = if hasScheme {
      makeUrl(input)
    } else {
      makeUrlWithBase(input, "http://localhost")
    }
    Ok(u)
  } catch {
  | _ => Error()
  }
}

// `paramsGet` returns `null` for absent keys and a decoded string otherwise.
// Treat empty-string the same as absent so `?repo=&symbol=Foo` fails BadRequest.
let required = (params: urlSearchParams, key: string): result<string, unit> =>
  switch Null.toOption(paramsGet(params, key)) {
  | Some(v) if v !== "" => Ok(v)
  | _ => Error()
  }

let optional = (params: urlSearchParams, key: string): option<string> =>
  switch Null.toOption(paramsGet(params, key)) {
  | Some(v) if v !== "" => Some(v)
  | _ => None
  }

// --- Public API -----------------------------------------------------------

let parse = (input: string): result<query, Wire.errorReason> =>
  switch toUrl(input) {
  | Error() => Error(Wire.BadRequest)
  | Ok(u) =>
    let params = searchParams(u)
    switch (required(params, "repo"), required(params, "symbol")) {
    | (Ok(repo), Ok(symbol)) =>
      Ok({
        repo,
        symbol,
        module_: optional(params, "module"),
        ref: optional(params, "ref"),
        file: optional(params, "file"),
      })
    | _ => Error(Wire.BadRequest)
    }
  }
