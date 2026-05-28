// Tests for TooltipController. Exercises:
//   - create() allocates a host node but doesn't insert into the DOM.
//   - show() inserts the host, renders the tooltip with the response,
//     and installs Esc + outside-click listeners.
//   - dismiss() removes the host and tears down listeners.
//   - Esc keydown → dismiss path.
//   - pin() promotes mode from Hover → Pinned.

@module("bun:test") external describe: (string, unit => unit) => unit = "describe"
@module("bun:test") external test: (string, unit => unit) => unit = "test"
@module("bun:test") external beforeAll: (unit => unit) => unit = "beforeAll"
@module("bun:test") external beforeEach: (unit => unit) => unit = "beforeEach"
@module("bun:test") external expect: 'a => 'expectation = "expect"
@send external toBe: ('expectation, 'a) => unit = "toBe"
@send external toContain: ('expectation, string) => unit = "toContain"

type registerOpts = {url: string}
@module("@happy-dom/global-registrator") @scope("GlobalRegistrator")
external register: registerOpts => unit = "register"

let safeRegister = (): unit =>
  try register({url: "https://github.com/"}) catch {
  | _ => ()
  }

@val external document: Dom.document = "document"
@get external documentBody: Dom.document => Dom.element = "body"
@send external createElement: (Dom.document, string) => Dom.element = "createElement"
@send external appendChild: (Dom.element, Dom.element) => Dom.element = "appendChild"
@set external setInnerHTML: (Dom.element, string) => unit = "innerHTML"
@get external textContent: Dom.element => string = "textContent"
@send
external bodyQuerySelector: (Dom.element, string) => Null.t<Dom.element> = "querySelector"

// KeyboardEvent constructor — synthetic for the Esc test.
type keyboardEventInit = {key: string, bubbles: bool}
type keyboardEvent
@new external makeKeyboardEvent: (string, keyboardEventInit) => keyboardEvent =
  "KeyboardEvent"
@send external dispatchKbdEvent: (Dom.document, keyboardEvent) => bool = "dispatchEvent"

type mouseEventInit = {bubbles: bool}
type mouseEvent
@new external makeMouseEvent: (string, mouseEventInit) => mouseEvent = "MouseEvent"
@send external dispatchMouseEventOnEl: (Dom.element, mouseEvent) => bool = "dispatchEvent"

beforeAll(() => {
  safeRegister()
  ActEnv.enableReactActEnvironment()
})

beforeEach(() => {
  documentBody(document)->setInnerHTML("")
})

// --- Shared fixtures ---------------------------------------------------

let makeSpan = (): Dom.element => {
  let el = document->createElement("span")
  let _ = documentBody(document)->appendChild(el)
  el
}

let sampleDef: Wire.definition = {
  symbol: "InstanceStep",
  module_: "Model.Process.InstanceStep",
  file: "src/Model/Process/InstanceStep.elm",
  line: 42,
  source: "type alias InstanceStep =\n    { id : Int }",
}

let okResponse: Wire.response = Wire.Ok({results: [sampleDef]})

// --- Tests -------------------------------------------------------------

describe("TooltipController.create", () => {
  test("create() does not insert host into document", () => {
    let _c = TooltipController.create()
    let inDoc = documentBody(document)->bodyQuerySelector(".elm-peek-tooltip")
    expect(inDoc->Null.toOption === None)->toBe(true)
  })
})

describe("TooltipController.show", () => {
  test("show() inserts a .elm-peek-tooltip and renders the result", () => {
    let span = makeSpan()
    let c = TooltipController.create()
    ActEnv.act(() => TooltipController.show(c, ~span, ~response=Ok(okResponse)))
    let found = documentBody(document)->bodyQuerySelector(".elm-peek-tooltip")
    expect(found->Null.toOption !== None)->toBe(true)
    switch found->Null.toOption {
    | Some(el) =>
      let txt = el->textContent
      expect(txt)->toContain("Model.Process.InstanceStep.InstanceStep")
      expect(txt)->toContain("type alias InstanceStep")
    | None => ()
    }
  })

  test("show() with Ok([]) renders NotFound state", () => {
    let span = makeSpan()
    let c = TooltipController.create()
    ActEnv.act(() =>
      TooltipController.show(c, ~span, ~response=Ok(Wire.Ok({results: []})))
    )
    let found = documentBody(document)->bodyQuerySelector(".elm-peek-tooltip")
    switch found->Null.toOption {
    | Some(el) => expect(el->textContent)->toContain("No definition found")
    | None => expect(false)->toBe(true)
    }
  })

  test("show() with Err(ElmqFailed) renders Error state", () => {
    let span = makeSpan()
    let c = TooltipController.create()
    ActEnv.act(() =>
      TooltipController.show(
        c,
        ~span,
        ~response=Ok(Wire.Err({reason: Wire.ElmqFailed, detail: "exit 7"})),
      )
    )
    let found = documentBody(document)->bodyQuerySelector(".elm-peek-tooltip")
    switch found->Null.toOption {
    | Some(el) =>
      let txt = el->textContent
      expect(txt)->toContain("Error")
      expect(txt)->toContain("exit 7")
    | None => expect(false)->toBe(true)
    }
  })

  test("show() with DecodeFailed (Error wrapper) renders Error state", () => {
    let span = makeSpan()
    let c = TooltipController.create()
    ActEnv.act(() =>
      TooltipController.show(c, ~span, ~response=Error("bad json"))
    )
    let found = documentBody(document)->bodyQuerySelector(".elm-peek-tooltip")
    switch found->Null.toOption {
    | Some(el) => expect(el->textContent)->toContain("bad json")
    | None => expect(false)->toBe(true)
    }
  })
})

describe("TooltipController.dismiss", () => {
  test("dismiss() removes the host node from the document", () => {
    let span = makeSpan()
    let c = TooltipController.create()
    ActEnv.act(() => TooltipController.show(c, ~span, ~response=Ok(okResponse)))
    let beforeFound = documentBody(document)->bodyQuerySelector(".elm-peek-tooltip")
    expect(beforeFound->Null.toOption !== None)->toBe(true)
    ActEnv.act(() => TooltipController.dismiss(c))
    let afterFound = documentBody(document)->bodyQuerySelector(".elm-peek-tooltip")
    expect(afterFound->Null.toOption === None)->toBe(true)
    expect(TooltipController.isVisible(c))->toBe(false)
  })

  test("dismiss() is idempotent", () => {
    let span = makeSpan()
    let c = TooltipController.create()
    ActEnv.act(() => TooltipController.show(c, ~span, ~response=Ok(okResponse)))
    ActEnv.act(() => TooltipController.dismiss(c))
    ActEnv.act(() => TooltipController.dismiss(c)) // should not throw
    expect(TooltipController.isVisible(c))->toBe(false)
  })
})

describe("TooltipController — Esc keydown dismisses", () => {
  test("Esc keydown on document → dismiss", () => {
    let span = makeSpan()
    let c = TooltipController.create()
    ActEnv.act(() => TooltipController.show(c, ~span, ~response=Ok(okResponse)))
    expect(TooltipController.isVisible(c))->toBe(true)
    let ev = makeKeyboardEvent("keydown", {key: "Escape", bubbles: true})
    ActEnv.act(() => {
      let _ = document->dispatchKbdEvent(ev)
    })
    expect(TooltipController.isVisible(c))->toBe(false)
  })
})

describe("TooltipController.pin", () => {
  test("pin() promotes mode to Pinned (DOM still rendered)", () => {
    let span = makeSpan()
    let c = TooltipController.create()
    ActEnv.act(() => TooltipController.show(c, ~span, ~response=Ok(okResponse)))
    ActEnv.act(() => TooltipController.pin(c))
    let found = documentBody(document)->bodyQuerySelector(".elm-peek-mode-pinned")
    expect(found->Null.toOption !== None)->toBe(true)
  })
})

describe("TooltipController — re-show updates content", () => {
  test("calling show() twice replaces the previous content", () => {
    let span1 = makeSpan()
    let c = TooltipController.create()
    ActEnv.act(() => TooltipController.show(c, ~span=span1, ~response=Ok(okResponse)))
    let firstText =
      documentBody(document)
      ->bodyQuerySelector(".elm-peek-tooltip")
      ->Null.toOption
      ->Option.map(el => el->textContent)
      ->Option.getOr("")
    expect(firstText)->toContain("InstanceStep")

    let otherDef: Wire.definition = {
      symbol: "Foo",
      module_: "M",
      file: "f.elm",
      line: 1,
      source: "type Foo = Bar",
    }
    let span2 = makeSpan()
    ActEnv.act(() =>
      TooltipController.show(c, ~span=span2, ~response=Ok(Wire.Ok({results: [otherDef]})))
    )
    let secondText =
      documentBody(document)
      ->bodyQuerySelector(".elm-peek-tooltip")
      ->Null.toOption
      ->Option.map(el => el->textContent)
      ->Option.getOr("")
    expect(secondText)->toContain("M.Foo")
  })
})

let _ = sampleDef.line // silence unused-field warning if any
let _ = makeMouseEvent
let _ = dispatchMouseEventOnEl
