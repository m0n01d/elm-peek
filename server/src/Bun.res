// Typed bindings for the Bun runtime APIs we use.
// See https://bun.com/docs/api/http and https://bun.com/docs/api/spawn.
//
// Keep this file small and audit-friendly: every binding here is something
// Server.res, Elmq.res, or a test calls. Widened once in P0 so no later slice
// has to reopen this file.

// --- Request --------------------------------------------------------------

type request
@get external requestUrl: request => string = "url"
@get external requestMethod: request => string = "method"

// --- Response -------------------------------------------------------------

type response

type responseInit = {
  status?: int,
  headers?: dict<string>,
}

@new external makeResponse: (string, responseInit) => response = "Response"
@new external makeEmptyResponse: (Null.t<string>, responseInit) => response = "Response"

// --- Bun.serve ------------------------------------------------------------

// TLS for Bun.serve. cert/key are PEM string contents. Used by Server.res
// when ~/.config/elm-peek/{cert,key}.pem exist (Safari can't fetch http://
// from an https://github.com page — mixed content). Plain HTTP boots when
// the field is absent.
type tlsOptions = {
  cert: string,
  key: string,
}

type serveOptions = {
  port: int,
  hostname: string,
  tls?: tlsOptions,
  fetch: request => promise<response>,
}

// Handle returned by Bun.serve. Lets tests pick an ephemeral port (`port: 0`)
// and stop the server between cases.
type server
@get external serverPort: server => int = "port"
@send external serverStop: server => unit = "stop"

@scope("Bun") @val external serve: serveOptions => server = "serve"

// --- Bun.spawnSync --------------------------------------------------------
// Used by Elmq.res to invoke the elmq CLI synchronously. Arg array (no shell)
// per SPEC.md#security.

type spawnSyncOptions = {
  cmd: array<string>,
  cwd?: string,
}

// stdout/stderr come back as Bun Buffers (Uint8Array subclass). Type them as
// an opaque `buffer` plus a `bufferToString` decoder rather than letting
// callers reach into the JS object shape.
type buffer
@send external bufferToString: buffer => string = "toString"

type spawnSyncResult = {
  exitCode: int,
  stdout: buffer,
  stderr: buffer,
}

@scope("Bun") @val external spawnSync: spawnSyncOptions => spawnSyncResult = "spawnSync"
