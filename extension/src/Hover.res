// Binds debounced hover + immediate click to a DOM element.
//
// Per SPEC §"Hover handler":
//   - 200ms stable-hover debounce before firing the lookup.
//   - Show loading state only after a further 300ms (avoids flicker for
//     fast responses).
//   - Click pins: fires onTrigger immediately, no debounce.
//
// Design choice: this is a small imperative observer rather than a TEA
// reducer. State is two timer ids; the "model" is implicit in whether
// they're populated. A useReducer model here would add ceremony without
// clarifying behaviour. The Tooltip (Slice 4) is where TEA-style state
// machine truly earns its keep.
//
// The clock is injected so unit tests can run synthetic time. In
// production, `realClock` wraps globalThis.setTimeout/clearTimeout.

// --- Public types -------------------------------------------------------

type cleanup = unit => unit

type clock = {
  setTimeout: (unit => unit, int) => int,
  clearTimeout: int => unit,
}

// --- Timing constants ---------------------------------------------------

let hoverDebounceMs = 200
let loadingFlickerGuardMs = 300

// --- realClock binding --------------------------------------------------

@val external globalSetTimeout: (unit => unit, int) => int = "setTimeout"
@val external globalClearTimeout: int => unit = "clearTimeout"

let realClock: clock = {
  setTimeout: globalSetTimeout,
  clearTimeout: globalClearTimeout,
}

// --- DOM event bindings -------------------------------------------------
//
// Minimal typed surface — no `{..}`, no rescript-webapi. `addEventListener`
// and `removeEventListener` take the same handler reference so we can
// detach cleanly.

type listener = unit => unit

@send
external addEventListener: (Dom.element, string, listener) => unit = "addEventListener"
@send
external removeEventListener: (Dom.element, string, listener) => unit = "removeEventListener"

// Capture-phase click listener. GitHub's blob view binds its own click
// handlers on syntax-highlighted spans for the built-in code-nav popover —
// those fire first in the bubble phase and prevent ours from firing. We
// register in capture phase and stopPropagation so our tooltip wins.
type addOptions = {capture: bool}
type eventListener = Dom.event => unit
@send external addCaptureListener: (Dom.element, string, eventListener, addOptions) => unit = "addEventListener"
@send external removeCaptureListener: (Dom.element, string, eventListener, addOptions) => unit = "removeEventListener"
@send external stopPropagation: Dom.event => unit = "stopPropagation"
@send external preventDefault: Dom.event => unit = "preventDefault"

// --- bind ---------------------------------------------------------------

let bind = (
  ~clock: clock=realClock,
  ~element: Dom.element,
  ~onTrigger: unit => unit,
  ~onLoadingVisible: unit => unit=() => (),
  ~clickOnly: bool=false,
): cleanup => {
  let hoverTimer = ref(None)
  let loadingTimer = ref(None)
  let disposed = ref(false)

  let cancelHoverTimer = () =>
    switch hoverTimer.contents {
    | Some(id) =>
      clock.clearTimeout(id)
      hoverTimer := None
    | None => ()
    }

  let cancelLoadingTimer = () =>
    switch loadingTimer.contents {
    | Some(id) =>
      clock.clearTimeout(id)
      loadingTimer := None
    | None => ()
    }

  let trigger = () =>
    if !disposed.contents {
      onTrigger()
      // Schedule the loading-visible callback. The consumer is expected
      // to dismiss this if the response arrives in time; for v1 we just
      // fire it unconditionally after the flicker guard.
      cancelLoadingTimer()
      let id = clock.setTimeout(() => {
        loadingTimer := None
        if !disposed.contents {
          onLoadingVisible()
        }
      }, loadingFlickerGuardMs)
      loadingTimer := Some(id)
    }

  let onEnter: listener = () =>
    if !disposed.contents {
      cancelHoverTimer()
      let id = clock.setTimeout(() => {
        hoverTimer := None
        trigger()
      }, hoverDebounceMs)
      hoverTimer := Some(id)
    }

  let onLeave: listener = () =>
    if !disposed.contents {
      cancelHoverTimer()
    }

  let onClickCapture: eventListener = ev =>
    if !disposed.contents {
      // Beat GitHub's bubble-phase code-nav handler.
      stopPropagation(ev)
      preventDefault(ev)
      cancelHoverTimer()
      trigger()
    }

  if !clickOnly {
    element->addEventListener("mouseenter", onEnter)
    element->addEventListener("mouseleave", onLeave)
  }
  element->addCaptureListener("click", onClickCapture, {capture: true})

  () => {
    disposed := true
    cancelHoverTimer()
    cancelLoadingTimer()
    if !clickOnly {
      element->removeEventListener("mouseenter", onEnter)
      element->removeEventListener("mouseleave", onLeave)
    }
    element->removeCaptureListener("click", onClickCapture, {capture: true})
  }
}
