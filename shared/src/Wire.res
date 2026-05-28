// Single source of truth for the elm-peek wire protocol.
// Spec: SPEC.md#wire-protocol.
//
// The JSON field for `module_` is `module` (reserved word in ReScript).
// errorReason values are kebab-case strings on the wire.

type definition = {
  symbol: string,
  module_: string,
  file: string,
  line: int,
  source: string,
}

type errorReason =
  | RepoNotMapped
  | NotFound
  | ElmqFailed
  | BadRequest

type response =
  | Ok({results: array<definition>})
  | Err({reason: errorReason, detail: string})

let reasonToString = (r: errorReason): string =>
  switch r {
  | RepoNotMapped => "repo-not-mapped"
  | NotFound => "not-found"
  | ElmqFailed => "elmq-failed"
  | BadRequest => "bad-request"
  }

let reasonFromString = (s: string): option<errorReason> =>
  switch s {
  | "repo-not-mapped" => Some(RepoNotMapped)
  | "not-found" => Some(NotFound)
  | "elmq-failed" => Some(ElmqFailed)
  | "bad-request" => Some(BadRequest)
  | _ => None
  }

// --- Encode ---------------------------------------------------------------

let encodeDefinition = (d: definition): JSON.t =>
  JSON.Object(
    Dict.fromArray([
      ("symbol", JSON.String(d.symbol)),
      ("module", JSON.String(d.module_)),
      ("file", JSON.String(d.file)),
      ("line", JSON.Number(Int.toFloat(d.line))),
      ("source", JSON.String(d.source)),
    ]),
  )

let encodeJson = (r: response): JSON.t =>
  switch r {
  | Ok({results}) =>
    JSON.Object(
      Dict.fromArray([
        ("kind", JSON.String("ok")),
        ("results", JSON.Array(results->Array.map(encodeDefinition))),
      ]),
    )
  | Err({reason, detail}) =>
    JSON.Object(
      Dict.fromArray([
        ("kind", JSON.String("error")),
        ("reason", JSON.String(reasonToString(reason))),
        ("detail", JSON.String(detail)),
      ]),
    )
  }

let encode = (r: response): string => r->encodeJson->JSON.stringify

// --- Decode ---------------------------------------------------------------

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

let decodeDefinition = (j: JSON.t): result<definition, string> =>
  switch j {
  | JSON.Object(d) =>
    switch (
      d->getString("symbol"),
      d->getString("module"),
      d->getString("file"),
      d->getInt("line"),
      d->getString("source"),
    ) {
    | (Ok(symbol), Ok(module_), Ok(file), Ok(line), Ok(source)) =>
      Ok({symbol, module_, file, line, source})
    | (Error(e), _, _, _, _)
    | (_, Error(e), _, _, _)
    | (_, _, Error(e), _, _)
    | (_, _, _, Error(e), _)
    | (_, _, _, _, Error(e)) =>
      Error(e)
    }
  | _ => Error("definition is not an object")
  }

let decodeJson = (j: JSON.t): result<response, string> =>
  switch j {
  | JSON.Object(d) =>
    switch d->getString("kind") {
    | Ok("ok") =>
      switch d->Dict.get("results") {
      | Some(JSON.Array(arr)) =>
        let decoded = arr->Array.map(decodeDefinition)
        switch decoded->Array.find(r =>
          switch r {
          | Error(_) => true
          | _ => false
          }
        ) {
        | Some(Error(e)) => Error(e)
        | _ =>
          let defs = decoded->Array.filterMap(r =>
            switch r {
            | Ok(def) => Some(def)
            | Error(_) => None
            }
          )
          Ok(Ok({results: defs}))
        }
      | _ => Error(`"results" missing or not an array`)
      }
    | Ok("error") =>
      switch (d->getString("reason"), d->getString("detail")) {
      | (Ok(reasonStr), Ok(detail)) =>
        switch reasonFromString(reasonStr) {
        | Some(reason) => Ok(Err({reason, detail}))
        | None => Error(`unknown reason: ${reasonStr}`)
        }
      | (Error(e), _) | (_, Error(e)) => Error(e)
      }
    | Ok(k) => Error(`unknown kind: ${k}`)
    | Error(e) => Error(e)
    }
  | _ => Error("response is not an object")
  }

let decode = (s: string): result<response, string> =>
  switch JSON.parseOrThrow(s) {
  | j => decodeJson(j)
  | exception _ => Error("invalid JSON")
  }
