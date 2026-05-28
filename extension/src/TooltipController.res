// Bridge between ContentScript's imperative orchestration and the
// React-rendered <Tooltip>. The controller owns:
//
//   - a host `<div>` appended to `document.body` (positioned absolute),
//   - a React root mounted into that host,
//   - the current `Tooltip.model`,
//   - global Esc / outside-click listeners.
//
// On `show(controller, ~span, ~response)`:
//   - position the host node next to `span` via Position.compute,
//   - feed the response into the reducer (Triggered or DecodeFailed),
//   - re-render the React tree with the new model,
//   - install Esc and outside-click listeners on document if not already.
//
// On `dismiss(controller)`: tear down listeners, unmount the React tree
// (so effects can clean up), and detach the host node from the DOM.
//
// The controller-side reducer pattern (rather than `useReducer` inside
// <Tooltip>) lets *external* events — Esc, outside-click, click-on-span
// — drive the state machine without smuggling refs into the component.
// The view stays pure: it reads `model` and emits messages via
// `dispatch`. CLAUDE.md TEA.

// ResizeObserver: fires whenever the host changes size (e.g. Loading text →
// fully rendered definition). Lets us re-run position() at the moment the
// real dimensions are known, instead of relying on rAF timing.
type resizeObserver
@new external makeResizeObserver: (unit => unit) => resizeObserver = "ResizeObserver"
@send external resizeObserve: (resizeObserver, Dom.element) => unit = "observe"
@send external resizeDisconnect: resizeObserver => unit = "disconnect"

type controller = {
  host: Dom.element,
  root: ReactDOM.Client.Root.t,
  model: ref<Tooltip.model>,
  // Listener handles so we can detach. Stored as options because we
  // only attach when visible and detach on dismiss.
  escListener: ref<option<Dom.event => unit>>,
  clickListener: ref<option<Dom.event => unit>>,
  visible: ref<bool>,
  // Current target span, so the ResizeObserver callback (which fires
  // whenever the host resizes) can re-run position math with up-to-date
  // dimensions. Cleared on dismiss.
  currentSpan: ref<option<Dom.element>>,
  // Repo of the currently-rendered tooltip — Tooltip uses it to build
  // GitHub blob URLs for the module header and disambiguation list.
  currentRepo: ref<option<string>>,
  // Ref (branch / sha) for those GitHub blob URLs. On PR diffs this is
  // the head branch so links point at the file as it appears in the diff
  // (not HEAD, which would miss variants added in the PR).
  currentRef: ref<option<string>>,
  // The actual symbol the user clicked. When it differs from the resolved
  // result's `decl` (variant-fallback case), the tooltip header shows
  // "Module.ParentType → ClickedSymbol" so the relationship is explicit.
  currentClickedSymbol: ref<option<string>>,
  resizeObserver: ref<option<resizeObserver>>,
}

// --- DOM bindings (typed, no `{..}`) -----------------------------------

@val external document: Dom.document = "document"
@get external documentBody: Dom.document => Dom.element = "body"
@get external documentHead: Dom.document => Dom.element = "head"
@get external documentElement: Dom.document => Dom.element = "documentElement"
@send external createElement: (Dom.document, string) => Dom.element = "createElement"
@send external appendChild: (Dom.element, Dom.element) => Dom.element = "appendChild"
@send external removeChild: (Dom.element, Dom.element) => Dom.element = "removeChild"
@send external contains: (Dom.element, Dom.element) => bool = "contains"
@send external bodyContains: (Dom.element, Dom.element) => bool = "contains"
@get external parentNode: Dom.element => Null.t<Dom.element> = "parentNode"
@set external setTextContent: (Dom.element, string) => unit = "textContent"
@set external setElementId: (Dom.element, string) => unit = "id"
@set external setClassName: (Dom.element, string) => unit = "className"

// style is a separate object on Dom.element; we only touch the few
// CSS properties we need and keep them as plain strings so the
// browser parses them. No `{..}`.
type cssStyle
@get external elementStyle: Dom.element => cssStyle = "style"
@set external setStyleTop: (cssStyle, string) => unit = "top"
@set external setStyleLeft: (cssStyle, string) => unit = "left"
@set external setStylePosition: (cssStyle, string) => unit = "position"
@set external setStyleZIndex: (cssStyle, string) => unit = "zIndex"

// getBoundingClientRect — happy-dom and real browsers both expose this.
type domRect = {
  top: float,
  left: float,
  bottom: float,
  right: float,
  width: float,
  height: float,
}
@send external getBoundingClientRect: Dom.element => domRect = "getBoundingClientRect"

// Window / viewport metrics.
@val external windowInnerWidth: float = "innerWidth"
@val external windowInnerHeight: float = "innerHeight"
@val external windowScrollX: float = "scrollX"
@val external windowScrollY: float = "scrollY"

// Re-position after React commits so we measure real dimensions.
@val external requestAnimationFrame: (unit => unit) => int = "requestAnimationFrame"

// Event listeners on the document, typed so we can detach by reference.
@send external addDocListener: (Dom.document, string, Dom.event => unit) => unit =
  "addEventListener"
@send external removeDocListener: (Dom.document, string, Dom.event => unit) => unit =
  "removeEventListener"

// KeyboardEvent.key
@get external eventKey: Dom.event => string = "key"
@get external eventTarget: Dom.event => Null.t<Dom.element> = "target"

let hostClass = "elm-peek-host"
let styleElementId = "elm-peek-styles"

// --- CSS injection ------------------------------------------------------
//
// One <style> appended to <head> on first controller creation. Idempotent
// via the unique id. Solid background + neutral palette + dark-mode variant
// so the tooltip reads on both GitHub themes without computing the active
// theme from the page.

let stylesheet = `
.elm-peek-host, .elm-peek-host * { box-sizing: border-box; }
.elm-peek-tooltip {
  background: #ffffff;
  color: #1f2328;
  border: 1px solid #d0d7de;
  border-radius: 6px;
  box-shadow: 0 8px 24px rgba(140, 149, 159, 0.25);
  padding: 12px 14px;
  /* Hard ceiling: tooltip can never be wider than viewport minus safe area,
     regardless of where the position math placed its left edge. */
  max-width: min(560px, calc(100vw - 16px));
  max-height: 60vh;
  overflow: auto;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  font-size: 12px;
  line-height: 1.5;
  position: relative;
}
.elm-peek-header {
  font-weight: 600;
  font-size: 11px;
  color: #59636e;
  margin-bottom: 6px;
  padding-right: 24px;
}
.elm-peek-source {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 12px;
  margin: 0;
  white-space: pre-wrap;
  overflow-x: auto;
  color: #1f2328;
}
.elm-peek-loading,
.elm-peek-empty,
.elm-peek-error {
  padding: 4px 0;
  color: #59636e;
}
.elm-peek-error { color: #cf222e; }
.elm-peek-close {
  position: absolute;
  top: 4px;
  right: 6px;
  background: transparent;
  border: 0;
  font-size: 18px;
  line-height: 1;
  color: #59636e;
  cursor: pointer;
  padding: 2px 6px;
  border-radius: 4px;
}
.elm-peek-close:hover { background: #f6f8fa; color: #1f2328; }
.elm-peek-footer {
  margin-top: 10px;
  padding-top: 8px;
  border-top: 1px solid #d0d7de;
}
.elm-peek-footer-label {
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  color: #59636e;
  margin-bottom: 4px;
}
.elm-peek-footer-list {
  margin: 0;
  padding-left: 16px;
  font-size: 11px;
  color: #59636e;
}
.elm-peek-link {
  color: #0969da;
  text-decoration: none;
}
.elm-peek-link:hover { text-decoration: underline; }
.elm-peek-mode-pinned {
  box-shadow: 0 8px 24px rgba(9, 105, 218, 0.25), 0 0 0 2px #0969da;
}
/* Prism token palette — light. Mirrors GitHub's "Primer" colours so the
   tooltip reads like the page around it. The token names below match what
   prism-elm actually emits: comment, char, string, import-statement,
   keyword, builtin, number, operator, hvariable, constant, punctuation. */
.elm-peek-source .token.comment { color: #6e7781; font-style: italic; }
.elm-peek-source .token.keyword { color: #cf222e; }
.elm-peek-source .token.string,
.elm-peek-source .token.char { color: #0a3069; }
.elm-peek-source .token.number,
.elm-peek-source .token.builtin,
.elm-peek-source .token.boolean { color: #0550ae; }
/* token.constant = uppercase identifiers in Elm (types, type constructors,
   module-name segments). Orange like GitHub Primer class-name. */
.elm-peek-source .token.constant { color: #953800; }
.elm-peek-source .token.operator { color: #cf222e; }
.elm-peek-source .token.punctuation { color: #57606a; }
.elm-peek-source .token.hvariable { color: #1f2328; }
.elm-peek-source .token.import-statement { color: #cf222e; }
@media (prefers-color-scheme: dark) {
  .elm-peek-tooltip {
    background: #15191f;
    color: #f0f6fc;
    border-color: #30363d;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.5);
  }
  .elm-peek-source { color: #f0f6fc; }
  .elm-peek-header,
  .elm-peek-loading,
  .elm-peek-empty,
  .elm-peek-footer-label,
  .elm-peek-footer-list,
  .elm-peek-close { color: #9198a1; }
  .elm-peek-error { color: #ff7b72; }
  .elm-peek-close:hover { background: #1f2328; color: #f0f6fc; }
  .elm-peek-footer { border-top-color: #30363d; }
  .elm-peek-source .token.comment { color: #8b949e; }
  .elm-peek-source .token.keyword { color: #ff7b72; }
  .elm-peek-source .token.string,
  .elm-peek-source .token.char { color: #a5d6ff; }
  .elm-peek-source .token.number,
  .elm-peek-source .token.builtin,
  .elm-peek-source .token.boolean { color: #79c0ff; }
  .elm-peek-source .token.constant { color: #ffa657; }
  .elm-peek-source .token.operator { color: #ff7b72; }
  .elm-peek-source .token.punctuation { color: #c9d1d9; }
  .elm-peek-source .token.hvariable { color: #f0f6fc; }
  .elm-peek-source .token.import-statement { color: #ff7b72; }
  .elm-peek-link { color: #58a6ff; }
}
`

let stylesInjected = ref(false)
let injectStyles = (): unit =>
  if !stylesInjected.contents {
    let style = document->createElement("style")
    style->setElementId(styleElementId)
    style->setTextContent(stylesheet)
    let _ = documentHead(document)->appendChild(style)
    stylesInjected := true
  }

// --- Internal helpers --------------------------------------------------

let detachHost = (c: controller): unit => {
  switch c.host->parentNode->Null.toOption {
  | Some(parent) =>
    let _ = parent->removeChild(c.host)
  | None => ()
  }
}

let attachHost = (c: controller): unit =>
  if !(documentBody(document)->bodyContains(c.host)) {
    let _ = documentBody(document)->appendChild(c.host)
  }

let renderTree = (c: controller, ~onClose: unit => unit, ~dispatch: Tooltip.msg => unit): unit => {
  let repo = c.currentRepo.contents
  let gitRef = c.currentRef.contents
  let clickedSymbol = c.currentClickedSymbol.contents
  c.root->ReactDOM.Client.Root.render(
    <Tooltip model={c.model.contents} dispatch onClose ?repo ?gitRef ?clickedSymbol />,
  )
}

let position = (c: controller, ~span: Dom.element): unit => {
  let spanRect = span->getBoundingClientRect
  // tooltipSize: try to read the actual rendered host bounds. On first
  // show the host has not been laid out yet, so fall back to a sensible
  // default (480x200 from SPEC.md §"Tooltip UX").
  let hostRect = c.host->getBoundingClientRect
  let twMeasured = hostRect.width > 0.0 ? hostRect.width : 480.0
  // Cap the assumed width at viewport width minus safe-area paddings.
  // Without this, a stale measurement could pick a small width and put
  // the tooltip too far right; even with CSS max-width, the *measured*
  // value drives Position.compute's left-clamp.
  let twCap = windowInnerWidth -. 16.0
  let tw = twMeasured > twCap ? twCap : twMeasured
  let th = hostRect.height > 0.0 ? hostRect.height : 200.0
  let viewport: Position.viewport = {
    width: windowInnerWidth,
    height: windowInnerHeight,
    scrollX: windowScrollX,
    scrollY: windowScrollY,
  }
  let posRect: Position.rect = {
    top: spanRect.top,
    left: spanRect.left,
    bottom: spanRect.bottom,
    right: spanRect.right,
    width: spanRect.width,
    height: spanRect.height,
  }
  let anchor = Position.compute(~spanRect=posRect, ~tooltipSize=(tw, th), ~viewport)
  let style = c.host->elementStyle
  style->setStylePosition("absolute")
  style->setStyleTop(Float.toString(anchor.top) ++ "px")
  style->setStyleLeft(Float.toString(anchor.left) ++ "px")
  style->setStyleZIndex("2147483647") // top of stack — beats GitHub's nav
}

// --- Public API --------------------------------------------------------

let create = (): controller => {
  injectStyles()
  let host = document->createElement("div")
  host->setClassName(hostClass)
  let style = host->elementStyle
  style->setStylePosition("absolute")
  style->setStyleZIndex("2147483647")
  let root = ReactDOM.Client.createRoot(host)
  let currentSpan: ref<option<Dom.element>> = ref(None)
  let c = {
    host,
    root,
    model: ref(Tooltip.initialModel),
    escListener: ref(None),
    clickListener: ref(None),
    visible: ref(false),
    currentSpan,
    currentRepo: ref(None),
    currentRef: ref(None),
    currentClickedSymbol: ref(None),
    resizeObserver: ref(None),
  }
  // ResizeObserver re-positions whenever the host's box changes — this
  // covers the Loading → Ok transition without depending on rAF timing.
  let ro = makeResizeObserver(() =>
    switch currentSpan.contents {
    | Some(span) => position(c, ~span)
    | None => ()
    }
  )
  ro->resizeObserve(host)
  c.resizeObserver := Some(ro)
  c
}

// Forward-declared dispatch — declared `ref` so it can capture itself
// via the controller's renderTree call without a circular let-binding.
// Initialized lazily inside show().
let dispatchOf = (c: controller, ~onClose: unit => unit): (Tooltip.msg => unit) => {
  let rec d = (msg: Tooltip.msg) => {
    c.model := Tooltip.update(c.model.contents, msg)
    switch msg {
    | Tooltip.Dismiss => onClose()
    | _ => renderTree(c, ~onClose, ~dispatch=d)
    }
  }
  d
}

let dismiss = (c: controller): unit =>
  if c.visible.contents {
    c.visible := false
    c.currentSpan := None
    c.currentRepo := None
    c.currentRef := None
    c.currentClickedSymbol := None
    switch c.escListener.contents {
    | Some(h) =>
      document->removeDocListener("keydown", h)
      c.escListener := None
    | None => ()
    }
    switch c.clickListener.contents {
    | Some(h) =>
      document->removeDocListener("mousedown", h)
      c.clickListener := None
    | None => ()
    }
    c.root->ReactDOM.Client.Root.render(React.null)
    detachHost(c)
  }

let installListeners = (c: controller): unit => {
  // Esc keydown — dismiss.
  let escHandler = (ev: Dom.event) => {
    let key = ev->eventKey
    if key === "Escape" || key === "Esc" {
      dismiss(c)
    }
  }
  // Outside click — dismiss only if click target isn't inside the host.
  let clickHandler = (ev: Dom.event) =>
    switch ev->eventTarget->Null.toOption {
    | Some(t) =>
      if !(c.host->contains(t)) {
        dismiss(c)
      }
    | None => ()
    }
  document->addDocListener("keydown", escHandler)
  document->addDocListener("mousedown", clickHandler)
  c.escListener := Some(escHandler)
  c.clickListener := Some(clickHandler)
}

// Internal: mount + render + position in one go. Used by both show and
// showLoading. Position is queued via requestAnimationFrame so React has
// committed the tree and getBoundingClientRect reads real dimensions —
// without this, the first show used the 480x200 fallback and could spill
// past the viewport.
let mountAndRender = (
  c: controller,
  ~span: Dom.element,
  ~onClose: unit => unit,
  ~dispatch: Tooltip.msg => unit,
): unit => {
  c.currentSpan := Some(span)
  attachHost(c)
  renderTree(c, ~onClose, ~dispatch)
  position(c, ~span)
  // Second pass after layout so the clamp sees real width/height. The
  // ResizeObserver allocated in create() handles subsequent size changes
  // (Loading text → fully rendered definition).
  let _ = requestAnimationFrame(() => position(c, ~span))
  if !c.visible.contents {
    c.visible := true
    installListeners(c)
  }
}

let showLoading = (
  c: controller,
  ~span: Dom.element,
  ~repo: option<string>=?,
  ~ref: option<string>=?,
  ~clickedSymbol: option<string>=?,
  ~onClose: unit => unit=() => (),
): unit => {
  c.model := Tooltip.initialModel // {mode: Hover, state: Loading}
  c.currentRepo := repo
  c.currentRef := ref
  c.currentClickedSymbol := clickedSymbol
  let dispatch = dispatchOf(c, ~onClose=() => {
    dismiss(c)
    onClose()
  })
  mountAndRender(c, ~span, ~onClose=() => {
    dismiss(c)
    onClose()
  }, ~dispatch)
}

let show = (
  c: controller,
  ~span: Dom.element,
  ~response: result<Wire.response, string>,
  ~repo: option<string>=?,
  ~ref: option<string>=?,
  ~clickedSymbol: option<string>=?,
  ~onClose: unit => unit=() => (),
): unit => {
  switch repo {
  | Some(_) => c.currentRepo := repo
  | None => () // keep prior value if caller didn't update
  }
  switch ref {
  | Some(_) => c.currentRef := ref
  | None => ()
  }
  switch clickedSymbol {
  | Some(_) => c.currentClickedSymbol := clickedSymbol
  | None => ()
  }
  // If we're already mounted (e.g. showLoading just ran), don't reset the
  // model — just update with the new response. This lets the loading
  // panel transition smoothly to the result.
  if !c.visible.contents {
    c.model := Tooltip.initialModel
  }

  let msg = switch response {
  | Ok(resp) => Tooltip.Triggered(resp)
  | Error(detail) => Tooltip.DecodeFailed(detail)
  }
  c.model := Tooltip.update(c.model.contents, msg)

  let dispatch = dispatchOf(c, ~onClose=() => {
    dismiss(c)
    onClose()
  })

  mountAndRender(c, ~span, ~onClose=() => {
    dismiss(c)
    onClose()
  }, ~dispatch)
}

let pin = (c: controller): unit => {
  c.model := Tooltip.update(c.model.contents, Tooltip.Pin)
  let dispatch = dispatchOf(c, ~onClose=() => dismiss(c))
  renderTree(c, ~onClose=() => dismiss(c), ~dispatch)
}

let isVisible = (c: controller): bool => c.visible.contents

// Exposed for tests that want to assert on the rendered DOM directly.
let hostElement = (c: controller): Dom.element => c.host
