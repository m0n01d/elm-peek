// Test-environment shims used only from *_test.res files.
//
//   - `enableReactActEnvironment` sets `globalThis.IS_REACT_ACT_ENVIRONMENT
//     = true`. Without this, React 19 logs a warning on every render in
//     a test. We expose it through `Object.defineProperty` so the binding
//     stays typed (no `{..}`, no `Obj.magic`, no `%raw`).
//
//   - `act` / `actAsync` bind directly to React 19's `act` export from
//     `react` (NOT `react-dom/test-utils` — that path is deprecated and
//     emits warnings).

type globalObj
@val external globalThisObj: globalObj = "globalThis"

type definePropertyOpts = {value: bool, writable: bool, configurable: bool}
@scope("Object") @val
external defineProperty: (globalObj, string, definePropertyOpts) => unit = "defineProperty"

let enableReactActEnvironment = (): unit =>
  defineProperty(globalThisObj, "IS_REACT_ACT_ENVIRONMENT", {
    value: true,
    writable: true,
    configurable: true,
  })

// React 19's act() returns a thenable. For our purposes we always
// invoke it with a sync callback and ignore the returned promise — the
// scheduled work flushes synchronously inside happy-dom when act is
// invoked this way. (See React 19 release notes.)
type actReturn
@module("react") external reactAct: (unit => unit) => actReturn = "act"

let act = (f: unit => unit): unit => {
  let _ = reactAct(f)
}
