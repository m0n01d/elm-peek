// Tests for Hover — binds mouseenter/mouseleave/click to an element and
// fires `onTrigger` after a 200ms stable-hover debounce or immediately on
// click. `onLoadingVisible` fires 300ms after `onTrigger` if the consumer
// hasn't acknowledged completion yet (avoids loading-spinner flicker for
// fast responses; SPEC §"Hover handler").
//
// We inject a fake clock so the tests are deterministic — no real time.

@module("bun:test") external describe: (string, unit => unit) => unit = "describe"
@module("bun:test") external test: (string, unit => unit) => unit = "test"
@module("bun:test") external beforeAll: (unit => unit) => unit = "beforeAll"
@module("bun:test") external beforeEach: (unit => unit) => unit = "beforeEach"
@module("bun:test") external expect: 'a => 'expectation = "expect"
@send external toBe: ('expectation, 'a) => unit = "toBe"

// --- happy-dom registration (per-file, idempotent) ----------------------

type registerOpts = {url: string}
@module("@happy-dom/global-registrator") @scope("GlobalRegistrator")
external register: registerOpts => unit = "register"

let safeRegister = (): unit =>
  try register({url: "https://github.com/"}) catch {
  | _ => ()
  }

// --- DOM globals --------------------------------------------------------

@val external document: Dom.document = "document"
@get external documentBody: Dom.document => Dom.element = "body"
@send external createElement: (Dom.document, string) => Dom.element = "createElement"
@send external appendChild: (Dom.element, Dom.element) => Dom.element = "appendChild"
@set external setInnerHTML: (Dom.element, string) => unit = "innerHTML"

// Event types — keep minimal.
type domEvent
type eventInit = {bubbles: bool}
@new external makeEvent: (string, eventInit) => domEvent = "Event"
@send external dispatchEvent: (Dom.element, domEvent) => bool = "dispatchEvent"

// --- Fake clock ---------------------------------------------------------
//
// Each scheduled timeout gets an integer id and a target tick. `advance(n)`
// advances virtual time by `n` ms and fires every callback whose target is
// <= the new tick.

type pending = {id: int, target: int, cb: unit => unit, cancelled: ref<bool>}

let now = ref(0)
let nextId = ref(1)
let pending = ref([])

let resetClock = (): unit => {
  now := 0
  nextId := 1
  pending := []
}

let fakeSetTimeout = (cb: unit => unit, ms: int): int => {
  let id = nextId.contents
  nextId := id + 1
  let p = {id, target: now.contents + ms, cb, cancelled: ref(false)}
  pending := pending.contents->Array.concat([p])
  id
}

let fakeClearTimeout = (id: int): unit => {
  pending.contents->Array.forEach(p =>
    if p.id === id {
      p.cancelled := true
    }
  )
}

let advance = (ms: int): unit => {
  let targetTick = now.contents + ms
  // Drain repeatedly so callbacks that schedule further timeouts run too.
  let keepGoing = ref(true)
  while keepGoing.contents {
    // Find earliest non-cancelled pending whose target <= targetTick.
    let due =
      pending.contents->Array.filter(p => !p.cancelled.contents && p.target <= targetTick)
    let earliest = due->Array.reduce(None, (acc, p) =>
      switch acc {
      | None => Some(p)
      | Some(a) => p.target < a.target ? Some(p) : Some(a)
      }
    )
    switch earliest {
    | None =>
      now := targetTick
      keepGoing := false
    | Some(p) =>
      now := p.target
      p.cancelled := true // mark as fired so we don't re-run
      pending := pending.contents->Array.filter(q => q.id !== p.id)
      p.cb()
    }
  }
}

let fakeClock: Hover.clock = {
  setTimeout: fakeSetTimeout,
  clearTimeout: fakeClearTimeout,
}

// --- Test scaffolding ---------------------------------------------------

beforeAll(() => safeRegister())

beforeEach(() => {
  resetClock()
  documentBody(document)->setInnerHTML("")
})

let makeSpan = (): Dom.element => {
  let el = document->createElement("span")
  let _ = documentBody(document)->appendChild(el)
  el
}

let fire = (el: Dom.element, name: string): unit => {
  let _ = el->dispatchEvent(makeEvent(name, {bubbles: true}))
}

// --- Tests --------------------------------------------------------------

describe("Hover.bind — debounced hover", () => {
  test("does not fire onTrigger before 200ms", () => {
    let el = makeSpan()
    let triggered = ref(0)
    let _cleanup = Hover.bind(~clock=fakeClock, ~element=el, ~onTrigger=() =>
      triggered := triggered.contents + 1
    )
    fire(el, "mouseenter")
    advance(199)
    expect(triggered.contents)->toBe(0)
  })

  test("fires onTrigger exactly once at 200ms", () => {
    let el = makeSpan()
    let triggered = ref(0)
    let _cleanup = Hover.bind(~clock=fakeClock, ~element=el, ~onTrigger=() =>
      triggered := triggered.contents + 1
    )
    fire(el, "mouseenter")
    advance(200)
    expect(triggered.contents)->toBe(1)
  })

  test("mouseleave before 200ms cancels", () => {
    let el = makeSpan()
    let triggered = ref(0)
    let _cleanup = Hover.bind(~clock=fakeClock, ~element=el, ~onTrigger=() =>
      triggered := triggered.contents + 1
    )
    fire(el, "mouseenter")
    advance(100)
    fire(el, "mouseleave")
    advance(500)
    expect(triggered.contents)->toBe(0)
  })

  test("click fires immediately, no debounce", () => {
    let el = makeSpan()
    let triggered = ref(0)
    let _cleanup = Hover.bind(~clock=fakeClock, ~element=el, ~onTrigger=() =>
      triggered := triggered.contents + 1
    )
    fire(el, "click")
    expect(triggered.contents)->toBe(1)
  })
})

describe("Hover.bind — onLoadingVisible", () => {
  test("fires 300ms after onTrigger", () => {
    let el = makeSpan()
    let triggered = ref(0)
    let loadingVisible = ref(0)
    let _cleanup = Hover.bind(
      ~clock=fakeClock,
      ~element=el,
      ~onTrigger=() => triggered := triggered.contents + 1,
      ~onLoadingVisible=() => loadingVisible := loadingVisible.contents + 1,
    )
    fire(el, "mouseenter")
    advance(200)
    expect(triggered.contents)->toBe(1)
    advance(299)
    expect(loadingVisible.contents)->toBe(0)
    advance(1)
    expect(loadingVisible.contents)->toBe(1)
  })
})

describe("Hover.bind — cleanup", () => {
  test("cleanup removes listeners and pending timers", () => {
    let el = makeSpan()
    let triggered = ref(0)
    let cleanup = Hover.bind(~clock=fakeClock, ~element=el, ~onTrigger=() =>
      triggered := triggered.contents + 1
    )
    fire(el, "mouseenter")
    cleanup()
    advance(500)
    expect(triggered.contents)->toBe(0)
    // After cleanup, additional events should not fire either.
    fire(el, "click")
    expect(triggered.contents)->toBe(0)
  })
})
