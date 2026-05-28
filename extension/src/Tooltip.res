// React tooltip rendered next to the hovered/clicked token.
//
// TEA-style (per CLAUDE.md §"TEA-style state management"):
//   - `type model = { mode, state }` — full state shape.
//   - `type msg = ...` — every transition is a constructor.
//   - `let update : (model, msg) => model` is a pure reducer.
//   - The component uses no `useState`. The controller (which owns the
//     React root) drives the reducer via the `dispatch` prop passed in.
//
// We deliberately do NOT manage the reducer inside <Tooltip> itself
// because the controller needs to mutate state externally (e.g.
// dismiss on Esc or outside-click) and needs to render new state in
// response to network responses received outside React. Keeping
// model+dispatch as props lets the controller own the cell of truth
// while the view stays pure.
//
// Spec: SPEC.md §"Tooltip UX". Wire.definition is the canonical
// definition record; never duplicate it here.

// Prism-backed Elm syntax highlighting. The shim handles the side-effect
// import of prism-elm and returns sanitized HTML for dangerouslySetInnerHTML.
@module("./PrismShim.mjs") external highlightElm: string => string = "highlightElm"

type mode = Hover | Pinned

type state =
  | Loading
  | Ok(array<Wire.definition>)
  | NotFound
  // The fetch failed at the network layer — almost always means the local
  // server isn't running. Distinct from Error(_) so the view can render a
  // call-to-action with the start command.
  | ServerDown
  | Error(string)

type model = {
  mode: mode,
  state: state,
}

type msg =
  | Triggered(Wire.response)
  | DecodeFailed(string)
  | ServerUnreachable
  | Pin
  | Dismiss

let initialModel: model = {mode: Hover, state: Loading}

let update = (model: model, msg: msg): model =>
  switch msg {
  | Triggered(Wire.Ok({results})) =>
    let next = Array.length(results) === 0 ? NotFound : Ok(results)
    {...model, state: next}
  | Triggered(Wire.Err({reason: Wire.NotFound, _})) => {...model, state: NotFound}
  | Triggered(Wire.Err({detail, _})) => {...model, state: Error(detail)}
  | DecodeFailed(detail) => {...model, state: Error(detail)}
  | ServerUnreachable => {...model, state: ServerDown}
  | Pin => {...model, mode: Pinned}
  | Dismiss => model // controller unmounts; state is moot
  }

// --- View ---------------------------------------------------------------
//
// Inline minimal styling via class names prefixed `elm-peek-` so the host
// page's CSS layer (or our injected CSS, if added later) can target it.

// GitHub blob URL for a definition. `ref` is the branch or commit SHA
// detected from the page (PR head branch on PR diffs, the URL's <ref>
// segment on blob/commit/tree pages). Falls back to HEAD only when the
// extension couldn't determine one — at which point new-in-this-PR
// variants won't be on the linked page, but at least the link works.
// Line anchor reflects the local file's line. If the local checkout drifts
// from the remote branch (unpulled commits, local edits, different branch),
// #L<line> may land on the wrong line. Keep your checkout synced with the
// PR branch — `git fetch && git checkout origin/<head-ref>` — for the
// anchor to be accurate.
let githubBlobUrl = (~repo: string, ~gitRef: string, ~file: string, ~line: int): string =>
  `https://github.com/${repo}/blob/${gitRef}/${file}#L${Int.toString(line)}`

// When the click resolved via variant fallback, `def.symbol` is the parent
// type's name (e.g. `Msg`), not what the user clicked. Showing
// `Module.Msg → SomeVariant` makes the relationship explicit.
// When clickedSymbol matches def.symbol (the common case for exact-match
// resolutions), the arrow is omitted.
let renderHeader = (
  ~repo: option<string>,
  ~gitRef: option<string>,
  ~clickedSymbol: option<string>,
  def: Wire.definition,
): React.element => {
  let base = def.module_ ++ "." ++ def.symbol
  let label = switch clickedSymbol {
  | Some(s) if s !== def.symbol => `${base} → ${s}`
  | _ => base
  }
  let r = switch gitRef {
  | Some(r) => r
  | None => "HEAD"
  }
  switch repo {
  | Some(repoStr) =>
    <div className="elm-peek-header">
      <a
        className="elm-peek-link"
        href={githubBlobUrl(~repo=repoStr, ~gitRef=r, ~file=def.file, ~line=def.line)}
        target="_blank"
        rel="noopener noreferrer">
        {React.string(label)}
      </a>
    </div>
  | None => <div className="elm-peek-header"> {React.string(label)} </div>
  }
}

let renderSource = (def: Wire.definition): React.element => {
  let html = highlightElm(def.source)
  <pre className="elm-peek-source language-elm">
    <code
      className="language-elm"
      dangerouslySetInnerHTML={{"__html": html}}
    />
  </pre>
}

let renderResult = (
  ~repo: option<string>,
  ~gitRef: option<string>,
  ~clickedSymbol: option<string>,
  def: Wire.definition,
): React.element =>
  <div className="elm-peek-result">
    {renderHeader(~repo, ~gitRef, ~clickedSymbol, def)}
    {renderSource(def)}
  </div>

let renderDisambiguation = (
  ~repo: option<string>,
  ~gitRef: option<string>,
  others: array<Wire.definition>,
): React.element => {
  let r = switch gitRef {
  | Some(r) => r
  | None => "HEAD"
  }
  <div className="elm-peek-footer">
    <div className="elm-peek-footer-label">
      {React.string("Other matches:")}
    </div>
    <ul className="elm-peek-footer-list">
      {others
      ->Array.mapWithIndex((d, i) => {
        let label = d.module_ ++ "." ++ d.symbol
        let item = switch repo {
        | Some(repoStr) =>
          <a
            className="elm-peek-link"
            href={githubBlobUrl(~repo=repoStr, ~gitRef=r, ~file=d.file, ~line=d.line)}
            target="_blank"
            rel="noopener noreferrer">
            {React.string(label)}
          </a>
        | None => React.string(label)
        }
        <li key={Int.toString(i)} className="elm-peek-footer-item"> {item} </li>
      })
      ->React.array}
    </ul>
  </div>
}

@react.component
let make = (
  ~model: model,
  ~dispatch: msg => unit,
  ~onClose: unit => unit,
  ~repo: option<string>=?,
  ~gitRef: option<string>=?,
  ~clickedSymbol: option<string>=?,
) => {
  // dispatch + onClose are wired by the controller. We surface a close
  // button so users can dismiss without keyboard/outside-click — keeps
  // the tooltip accessible.
  let _ = dispatch

  let body = switch model.state {
  | Loading =>
    <div className="elm-peek-loading"> {React.string("Loading…")} </div>
  | NotFound =>
    <div className="elm-peek-empty"> {React.string("No definition found.")} </div>
  | ServerDown =>
    <div className="elm-peek-server-down">
      <div className="elm-peek-server-down-title">
        {React.string("elm-peek server isn't running")}
      </div>
      <div className="elm-peek-server-down-detail">
        {React.string("Start it with ")}
        <code className="elm-peek-server-down-cmd">
          {React.string("bun run dev:server")}
        </code>
        {React.string(" from your elm-peek checkout.")}
      </div>
    </div>
  | Error(msg) =>
    <div className="elm-peek-error"> {React.string("Error: " ++ msg)} </div>
  | Ok(results) =>
    switch Array.get(results, 0) {
    | None =>
      // Shouldn't happen — `update` upgrades empty Ok to NotFound — but
      // be defensive so a future code path that constructs Ok([]) by hand
      // doesn't render a blank box.
      <div className="elm-peek-empty"> {React.string("No definition found.")} </div>
    | Some(first) =>
      let rest = results->Array.slice(~start=1, ~end=Array.length(results))
      <>
        {renderResult(~repo, ~gitRef, ~clickedSymbol, first)}
        {Array.length(rest) > 0 ? renderDisambiguation(~repo, ~gitRef, rest) : React.null}
      </>
    }
  }

  let modeClass = switch model.mode {
  | Hover => "elm-peek-tooltip elm-peek-mode-hover"
  | Pinned => "elm-peek-tooltip elm-peek-mode-pinned"
  }

  <div className=modeClass role="dialog">
    <button
      className="elm-peek-close"
      ariaLabel="Close"
      onClick={_ => onClose()}>
      {React.string("×")}
    </button>
    {body}
  </div>
}
