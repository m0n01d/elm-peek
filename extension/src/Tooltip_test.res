// Tooltip_test — Step 0 outcome: React 19 + @rescript/react 0.15 + happy-dom
// under bun:test works. createRoot + render flushes synchronously in this
// combo, so we can assert on document text immediately after render(). No
// Vitest fallback needed.

@module("bun:test") external describe: (string, unit => unit) => unit = "describe"
@module("bun:test") external test: (string, unit => unit) => unit = "test"
@module("bun:test") external beforeAll: (unit => unit) => unit = "beforeAll"
@module("bun:test") external beforeEach: (unit => unit) => unit = "beforeEach"
@module("bun:test") external expect: 'a => 'expectation = "expect"
@send external toBe: ('expectation, 'a) => unit = "toBe"
@send external toContain: ('expectation, string) => unit = "toContain"

// --- happy-dom registration (idempotent) -------------------------------

type registerOpts = {url: string}
@module("@happy-dom/global-registrator") @scope("GlobalRegistrator")
external register: registerOpts => unit = "register"

let safeRegister = (): unit =>
  try register({url: "https://github.com/"}) catch {
  | _ => ()
  }

// React 19 requires this global flag to be set before act() will run
// effects without warning. We set it once at module init through a
// tiny `Object.defineProperty`-style writer rather than a `{..}`
// dynamic write (CLAUDE.md forbids untyped object types). Implemented
// in ActEnv.res — see that module for the typed binding details.
//
// Calling it during beforeAll is enough since bun runs tests within
// a single Node-like process.

// --- DOM globals --------------------------------------------------------

@val external document: Dom.document = "document"
@get external documentBody: Dom.document => Dom.element = "body"
@send external createElement: (Dom.document, string) => Dom.element = "createElement"
@send external appendChild: (Dom.element, Dom.element) => Dom.element = "appendChild"
@send external removeChild: (Dom.element, Dom.element) => Dom.element = "removeChild"
@set external setInnerHTML: (Dom.element, string) => unit = "innerHTML"
@get external getInnerHTML: Dom.element => string = "innerHTML"
@get external getTextContent: Dom.element => string = "textContent"

// --- React 19 root binding (verified working under happy-dom) ----------

beforeAll(() => {
  safeRegister()
  ActEnv.enableReactActEnvironment()
})

beforeEach(() => {
  documentBody(document)->setInnerHTML("")
})

let mountHost = (): Dom.element => {
  let host = document->createElement("div")
  let _ = documentBody(document)->appendChild(host)
  host
}

// --- Step 0 smoke -------------------------------------------------------
//
// React 19's createRoot().render() is async by default — to make tests
// deterministic we wrap render in ReactTestUtils.act (from react-dom/test-utils,
// which still works in React 19 via the back-compat shim). After act() returns,
// the DOM reflects the render. This is the standard pattern for React testing.

describe("Step 0 — React 19 + @rescript/react + happy-dom smoke", () => {
  test("createRoot + render (in act) flushes a <div>Hello</div> to the DOM", () => {
    let host = mountHost()
    let root = ReactDOM.Client.createRoot(host)
    ActEnv.act(() => {
      root->ReactDOM.Client.Root.render(<div> {React.string("Hello")} </div>)
    })
    let txt = host->getTextContent
    expect(txt)->toContain("Hello")
    ActEnv.act(() => {
      root->ReactDOM.Client.Root.unmount()
    })
  })
})

// --- Tooltip update tests (pure reducer) -------------------------------

describe("Tooltip.update", () => {
  test("initialModel is { mode: Hover, state: Loading }", () => {
    let m = Tooltip.initialModel
    expect(m.mode)->toBe(Tooltip.Hover)
    let isLoading = switch m.state {
    | Tooltip.Loading => true
    | _ => false
    }
    expect(isLoading)->toBe(true)
  })

  test("Triggered(Ok results) → state = Ok(results)", () => {
    let def: Wire.definition = {
      symbol: "Foo",
      module_: "M",
      file: "f.elm",
      line: 1,
      source: "type alias Foo = Int",
    }
    let m = Tooltip.update(Tooltip.initialModel, Tooltip.Triggered(Wire.Ok({results: [def]})))
    let ok = switch m.state {
    | Tooltip.Ok(arr) => Array.length(arr) === 1
    | _ => false
    }
    expect(ok)->toBe(true)
  })

  test("Triggered(Ok with 0 results) → state = NotFound", () => {
    let m = Tooltip.update(Tooltip.initialModel, Tooltip.Triggered(Wire.Ok({results: []})))
    let isNotFound = switch m.state {
    | Tooltip.NotFound => true
    | _ => false
    }
    expect(isNotFound)->toBe(true)
  })

  test("Triggered(Err NotFound) → state = NotFound", () => {
    let m = Tooltip.update(
      Tooltip.initialModel,
      Tooltip.Triggered(Wire.Err({reason: Wire.NotFound, detail: ""})),
    )
    let isNotFound = switch m.state {
    | Tooltip.NotFound => true
    | _ => false
    }
    expect(isNotFound)->toBe(true)
  })

  test("Triggered(Err Other) → state = Error(detail)", () => {
    let m = Tooltip.update(
      Tooltip.initialModel,
      Tooltip.Triggered(Wire.Err({reason: Wire.ElmqFailed, detail: "boom"})),
    )
    let isErr = switch m.state {
    | Tooltip.Error(s) => s === "boom"
    | _ => false
    }
    expect(isErr)->toBe(true)
  })

  test("DecodeFailed(msg) → state = Error(msg)", () => {
    let m = Tooltip.update(Tooltip.initialModel, Tooltip.DecodeFailed("bad json"))
    let isErr = switch m.state {
    | Tooltip.Error(s) => s === "bad json"
    | _ => false
    }
    expect(isErr)->toBe(true)
  })

  test("Pin → mode = Pinned (state unchanged)", () => {
    let def: Wire.definition = {
      symbol: "Foo",
      module_: "M",
      file: "f.elm",
      line: 1,
      source: "x",
    }
    let m1 = Tooltip.update(Tooltip.initialModel, Tooltip.Triggered(Wire.Ok({results: [def]})))
    let m2 = Tooltip.update(m1, Tooltip.Pin)
    expect(m2.mode)->toBe(Tooltip.Pinned)
    let still = switch m2.state {
    | Tooltip.Ok(_) => true
    | _ => false
    }
    expect(still)->toBe(true)
  })
})

// --- Tooltip render tests ----------------------------------------------

let renderTooltip = (~model: Tooltip.model): Dom.element => {
  let host = mountHost()
  let root = ReactDOM.Client.createRoot(host)
  ActEnv.act(() => {
    root->ReactDOM.Client.Root.render(
      <Tooltip model dispatch={_ => ()} onClose={() => ()} />,
    )
  })
  host
}

describe("Tooltip.view", () => {
  test("Loading state shows 'Loading' text", () => {
    let host = renderTooltip(~model={mode: Hover, state: Loading})
    expect(host->getTextContent)->toContain("Loading")
  })

  test("NotFound state shows 'No definition found'", () => {
    let host = renderTooltip(~model={mode: Hover, state: NotFound})
    expect(host->getTextContent)->toContain("No definition found")
  })

  test("Error state shows the error message", () => {
    let host = renderTooltip(~model={mode: Hover, state: Error("explode")})
    expect(host->getTextContent)->toContain("explode")
  })

  test("Ok with single result shows module.SymbolName and source", () => {
    let def: Wire.definition = {
      symbol: "InstanceStep",
      module_: "Model.Process.InstanceStep",
      file: "src/Model/Process/InstanceStep.elm",
      line: 42,
      source: "type alias InstanceStep =\n    { id : InstanceStepId\n    }",
    }
    let host = renderTooltip(~model={mode: Hover, state: Ok([def])})
    let txt = host->getTextContent
    expect(txt)->toContain("Model.Process.InstanceStep.InstanceStep")
    expect(txt)->toContain("type alias InstanceStep")
  })

  test("Ok with multiple results shows disambiguation footer", () => {
    let a: Wire.definition = {
      symbol: "Foo",
      module_: "ModA",
      file: "a.elm",
      line: 1,
      source: "type Foo = A",
    }
    let b: Wire.definition = {
      symbol: "Foo",
      module_: "ModB",
      file: "b.elm",
      line: 2,
      source: "type Foo = B",
    }
    let host = renderTooltip(~model={mode: Hover, state: Ok([a, b])})
    let txt = host->getTextContent
    // First result shown as main
    expect(txt)->toContain("ModA.Foo")
    // Other result appears in disambiguation footer
    expect(txt)->toContain("ModB")
  })
})
