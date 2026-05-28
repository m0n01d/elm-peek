// Content script entry point. Injected into matching GitHub pages.
//
// Slice 4 (current): the hover trigger now mounts a real <Tooltip>
// next to the hovered span via TooltipController. Slice 3's
// `lookupAndLog` is replaced by `lookupAndShow`, which fetches the
// /lookup endpoint and calls `TooltipController.show(controller,
// ~span, ~response)` with the decoded Wire envelope (or an Error
// wrapper on decode failure).
//
// Earlier-slice behaviour preserved:
//   - DOM-driven Elm file detection (blob/PR/commit pages).
//   - TokenScan + WeakSet dedupes capitalized-identifier spans.
//   - Hover.bind debounces hover (200ms) and fires immediately on click.
//   - MutationObserver re-scans the document as PR diffs lazy-load.
//
// One controller is allocated per page (lazily, the first time a hover
// fires) and reused across spans. show() repositions, re-renders, and
// reinstalls listeners — see TooltipController.res for details.

// HTTPS required by Safari (mixed-content block on https://github.com → http).
// Chrome/Firefox accept the mkcert-signed cert transparently after
// `mkcert -install` adds the local CA to the system trust store.
let serverUrl = "https://127.0.0.1:42069"

// --- Minimal typed bindings ----------------------------------------------

@scope("location") @val external pathname: string = "pathname"
@scope("location") @val external href: string = "href"

type fetchResponse = {ok: bool, status: int}
@send external responseText: fetchResponse => promise<string> = "text"
@val external fetch: string => promise<fetchResponse> = "fetch"

@val external document: Dom.document = "document"
@get external textContent: Dom.element => string = "textContent"
@send
external querySelectorAll: (Dom.document, string) => Dom.nodeList = "querySelectorAll"
@get external nodeListLength: Dom.nodeList => int = "length"
@send
external nodeListItem: (Dom.nodeList, int) => Null.t<Dom.element> = "item"

// Document-level delegated click handling. Per-span binding (via Hover.bind)
// fails on GitHub's redesigned blob view — the spans appear in our queries
// but our element-level listeners don't fire on click. Hypothesis: virtualized
// rendering replaces nodes after bind, or some overlay intercepts. Delegated
// at document level we always win on capture.
type addOptions = {capture: bool}
type eventListener = Dom.event => unit
@send external addDocClick: (Dom.document, string, eventListener, addOptions) => unit = "addEventListener"
@get external eventTarget: Dom.event => Null.t<Dom.element> = "target"
@send external stopPropagation: Dom.event => unit = "stopPropagation"
@send external preventDefault: Dom.event => unit = "preventDefault"

// Match the regex TokenScan uses so behaviour is identical.
let candidateRe = RegExp.fromString("^[A-Z][A-Za-z0-9_]*$")

// MutationObserver: invoked with mutation records we don't actually need
// to inspect — we just re-run the bound-spans scan on each callback. Bind
// the callback as `unit => unit` for simplicity; we ignore the records.
type mutationObserver
type mutationObserverInit = {childList: bool, subtree: bool}
@new
external makeMutationObserver: (unit => unit) => mutationObserver = "MutationObserver"
@send
external observe: (
  mutationObserver,
  Dom.element,
  mutationObserverInit,
) => unit = "observe"

@get external documentBody: Dom.document => Dom.element = "body"

// --- Selectors used for Elm-file detection -------------------------------
//
// GitHub exposes the file path via a few different attributes depending on
// the view. We use multiple selectors as fallbacks so a single redesign
// doesn't break detection.
//
// Per SPEC §"Token detection": don't pin to specific class names — these
// attribute-based selectors are far more stable than `.diff-table`.

let elmFileSelectors = [
  "[data-tagsearch-path$=\".elm\"]",
  "[title$=\".elm\"]",
  "[data-path$=\".elm\"]",
]

// --- Repo extraction -----------------------------------------------------
//
// GitHub URLs are `/<org>/<name>/(blob|pull|commit|tree)/...`. Extract the
// first two path segments. Returns None if the URL doesn't look like a
// repo URL (e.g. /settings, /).

let extractRepo = (path: string): option<string> => {
  let parts =
    path
    ->String.split("/")
    ->Array.filter(s => s !== "")
  switch (parts->Array.get(0), parts->Array.get(1)) {
  | (Some(org), Some(name)) => Some(org ++ "/" ++ name)
  | _ => None
  }
}

// --- File-path detection ------------------------------------------------
//
// Two strategies, in order:
//   1. DOM ancestor: GitHub diff views attach the file path to a container
//      around each file via `data-tagsearch-path`, `data-path`, or `title`.
//      We walk up from the clicked span to the nearest such container.
//   2. URL fallback: on blob pages the file path is the suffix after
//      `/<org>/<name>/blob/<ref>/`. Useful when the DOM walk fails or
//      we're on a single-file blob view that lacks the diff attributes.
//
// The result is sent as `file=` query param so the server can narrow elmq
// when the whole-repo pass returns empty (see Elmq.lookup's two-pass logic).

@send external closest: (Dom.element, string) => Null.t<Dom.element> = "closest"
@send external getAttribute: (Dom.element, string) => Null.t<string> = "getAttribute"
@get external previousElementSibling: Dom.element => Null.t<Dom.element> = "previousElementSibling"

// --- Qualified-reference detection -------------------------------------
//
// When the user clicks `Symbol` in a qualified reference like
// `Module.Symbol` (or `Alias.Symbol` for aliased imports), GitHub renders
// the parts as separate spans:
//   <span>Module</span><span>.</span><span>Symbol</span>
// We walk backward two siblings to detect the prefix. If found, the
// extension passes it as `module=<prefix>` so the server can resolve the
// alias via the file's imports and prioritize matches in that module.

let isCapitalizedIdent = (s: string): bool =>
  candidateRe->RegExp.test(String.trim(s))

let modulePrefix = (clicked: Dom.element): option<string> => {
  switch clicked->previousElementSibling->Null.toOption {
  | Some(dotEl) if String.trim(textContent(dotEl)) === "." =>
    switch dotEl->previousElementSibling->Null.toOption {
    | Some(prefixEl) =>
      let t = String.trim(textContent(prefixEl))
      if isCapitalizedIdent(t) {
        Some(t)
      } else {
        None
      }
    | None => None
    }
  | _ => None
  }
}

// Attribute selectors in priority order. Each maps to a function that
// extracts the file path from the matched element. The new GitHub PR diff
// view (PullRequestDiffsList) uses <table aria-label="Diff for: <path>"> on
// the diff table and <button data-file-path="<path>"> on the expand button.
// Older / blob views still expose data-tagsearch-path, data-path, title.

let stripDiffForPrefix = (s: string): option<string> => {
  let prefix = "Diff for: "
  if String.startsWith(s, prefix) {
    Some(String.slice(s, ~start=String.length(prefix), ~end=String.length(s)))
  } else {
    None
  }
}

let elmPathSources: array<(string, Dom.element => option<string>)> = [
  ("[data-tagsearch-path$=\".elm\"]", el =>
    el->getAttribute("data-tagsearch-path")->Null.toOption
  ),
  ("[data-path$=\".elm\"]", el => el->getAttribute("data-path")->Null.toOption),
  ("[data-file-path$=\".elm\"]", el =>
    el->getAttribute("data-file-path")->Null.toOption
  ),
  ("table[aria-label^=\"Diff for: \"][aria-label$=\".elm\"]", el =>
    switch el->getAttribute("aria-label")->Null.toOption {
    | Some(s) => stripDiffForPrefix(s)
    | None => None
    }
  ),
  ("[title$=\".elm\"]", el => el->getAttribute("title")->Null.toOption),
]

let findEnclosingFile = (el: Dom.element): option<string> => {
  let result = ref(None)
  elmPathSources->Array.forEach(((selector, extract)) =>
    if result.contents === None {
      switch el->closest(selector)->Null.toOption {
      | Some(container) =>
        switch extract(container) {
        | Some(v) if String.endsWith(v, ".elm") => result := Some(v)
        | _ => ()
        }
      | None => ()
      }
    }
  )
  result.contents
}

let fileFromUrl = (path: string): option<string> => {
  // /<org>/<name>/blob/<ref>/<file...>
  let parts = path->String.split("/")->Array.filter(s => s !== "")
  switch parts->Array.get(2) {
  | Some("blob") if Array.length(parts) >= 5 =>
    let fileParts = parts->Array.slice(~start=4, ~end=Array.length(parts))
    Some(fileParts->Array.join("/"))
  | _ => None
  }
}

// --- Ref (branch / sha) detection ---------------------------------------
//
// Goal: tooltip links go to the file as it appears in the PR's head branch,
// not HEAD of the default branch. A new variant added in the diff exists on
// the PR branch but not on main, so a /blob/HEAD/ link would 404 or show
// stale source.
//
// Strategy: on blob/commit/tree URLs the ref is in the path (parts[3]).
// On PR pages it isn't, so we mine the DOM — GitHub's own on-page links
// to `/blob/<ref>/` use the head branch name, so we scrape them. Prefer
// any ref that isn't a known default (main/master/develop/HEAD), since
// the head branch is the interesting one.

@get external linkHref: Dom.element => string = "href"

let defaultRefNames = ["main", "master", "develop", "HEAD"]

let refFromDom = (): option<string> => {
  let list = document->querySelectorAll("a[href*=\"/blob/\"], a[href*=\"/tree/\"]")
  let len = list->nodeListLength
  let seen: dict<bool> = Dict.make()
  let order: array<string> = []
  let re = RegExp.fromString("/(?:blob|tree)/([^/?#]+)")
  let i = ref(0)
  while i.contents < len {
    switch list->nodeListItem(i.contents)->Null.toOption {
    | Some(el) =>
      let href = el->linkHref
      switch RegExp.exec(re, href) {
      | Some(m) =>
        switch RegExp.Result.matches(m)->Array.get(0) {
        | Some(Some(r)) =>
          if seen->Dict.get(r) === None {
            seen->Dict.set(r, true)
            order->Array.push(r)
          }
        | _ => ()
        }
      | None => ()
      }
    | None => ()
    }
    i := i.contents + 1
  }
  // Prefer a non-default branch name (head of the PR) over main/master.
  let nonDefault = order->Array.find(r => !(defaultRefNames->Array.includes(r)))
  switch nonDefault {
  | Some(r) => Some(r)
  | None => order->Array.get(0)
  }
}

let detectRef = (): option<string> => {
  let parts = pathname->String.split("/")->Array.filter(s => s !== "")
  switch (parts->Array.get(2), parts->Array.get(3)) {
  | (Some("blob"), Some(r))
  | (Some("commit"), Some(r))
  | (Some("tree"), Some(r)) => Some(r)
  | _ => refFromDom()
  }
}

// --- Tooltip controller (one per page, lazy) ----------------------------
//
// Allocated on first hover. We delay allocation because creating a
// React root attaches a tree to a detached <div>; doing it eagerly on
// every Elm-detected page wastes work when the user never hovers
// anything.

let controller: ref<option<TooltipController.controller>> = ref(None)

let getController = (): TooltipController.controller =>
  switch controller.contents {
  | Some(c) => c
  | None =>
    let c = TooltipController.create()
    controller := Some(c)
    c
  }

// --- Lookup --------------------------------------------------------------
//
// Page-lifetime in-memory cache keyed by `${repo}::${symbol}`. The same
// symbol may appear in dozens of diff lines; re-clicking should be instant.
// We only cache responses we could fully decode (Wire.decode returned Ok) —
// decode failures and network errors are transient and shouldn't poison
// future lookups. Cache wipes on page reload, which is the right window
// since repos.json edits are picked up there too.

let cache: dict<Wire.response> = Dict.make()

// Cache key includes the file hint because variant-fallback results depend
// on which file the click came from. Without this, the first click for
// `SomeVariant` from one module's diff would return its parent type;
// every later click on the same symbol from a DIFFERENT module's diff would
// hit the cache and show the wrong module's type. With file in the key,
// each file's result is cached separately. Symbol clicks without a file
// hint still share an entry.
let cacheKey = (~repo: string, ~symbol: string, ~file: option<string>): string =>
  switch file {
  | Some(f) => `${repo}::${f}::${symbol}`
  | None => `${repo}::${symbol}`
  }

let lookupAndShow = (~repo: string, ~symbol: string, ~span: Dom.element): unit => {
  let c = getController()
  // file hint: prefer DOM container (works in diff/changes views), fall
  // back to URL (works in blob view). Either is optional — server's first
  // pass is whole-repo, file only kicks in when the wide pass is empty.
  let fileHint = switch findEnclosingFile(span) {
  | Some(f) => Some(f)
  | None => fileFromUrl(pathname)
  }
  // Ref for tooltip links: detected fresh per click so PR branch changes
  // (commits pushed mid-review) are picked up without page reload. Cheap
  // — DOM scan over `/blob/` and `/tree/` link hrefs.
  let refHint = detectRef()
  // Qualified-reference prefix: when clicking `Symbol` in `Prefix.Symbol`,
  // the prefix is the previous-previous element. Sent as `&module=<prefix>`
  // so the server can resolve it via the file's import alias map.
  let prefixHint = modulePrefix(span)
  let key = cacheKey(~repo, ~symbol, ~file=fileHint)
  let fileQ = switch fileHint {
  | Some(f) => `&file=${f}`
  | None => ""
  }
  let moduleQ = switch prefixHint {
  | Some(p) => `&module=${p}`
  | None => ""
  }
  switch cache->Dict.get(key) {
  | Some(cached) =>
    // Instant re-render. No loading, no fetch.
    TooltipController.show(c, ~span, ~response=Ok(cached), ~repo, ~ref=?refHint, ~clickedSymbol=symbol)
  | None =>
    let url = `${serverUrl}/lookup?repo=${repo}&symbol=${symbol}${fileQ}${moduleQ}`
    TooltipController.showLoading(c, ~span, ~repo, ~ref=?refHint, ~clickedSymbol=symbol)
    let _ =
      fetch(url)
      ->Promise.then(res => res->responseText)
      ->Promise.then(body => {
        let decoded = Wire.decode(body)
        switch decoded {
        | Ok(response) => cache->Dict.set(key, response)
        | Error(_) => () // transient; don't poison the cache
        }
        TooltipController.show(c, ~span, ~response=decoded, ~repo, ~ref=?refHint, ~clickedSymbol=symbol)
        Promise.resolve()
      })
      ->Promise.catch(err => {
        Console.log3("[elm-peek] fetch failed", symbol, err)
        // Network-layer failure almost always means the local server isn't
        // running. Surface a dedicated state with the start command so the
        // user doesn't have to remember it.
        TooltipController.showServerDown(
          c,
          ~span,
          ~repo,
          ~ref=?refHint,
          ~clickedSymbol=symbol,
        )
        Promise.resolve()
      })
  }
}

// --- Page-level Elm detection -------------------------------------------

let hasElmFile = (doc: Dom.document): bool => {
  let joined = elmFileSelectors->Array.join(",")
  let list = doc->querySelectorAll(joined)
  list->nodeListLength > 0
}

// --- Orchestration -------------------------------------------------------
//
// On every observer tick (and once on init), scan the document for new
// candidate spans and bind a Hover handler to each. TokenScan dedups via
// its WeakSet, so re-running the scan repeatedly is cheap.
//
// We don't bother tracking per-span cleanup handlers: the content script
// lives for the lifetime of the page, and the GC reclaims listeners when
// the spans are removed. Slice 4 may revisit if Tooltip mounting needs
// explicit teardown.

let bindNewSpans = (): unit => {
  let spans = TokenScan.findCandidateSpans(document)
  spans->Array.forEach(span => {
    let symbol = span->textContent
    // Click-only: hover firing fetches felt jumpy and re-triggered after
    // an explicit dismiss (X-out). Click is an intentional gesture; the
    // 200ms hover debounce stays in Hover.bind for future re-enable.
    let _cleanup = Hover.bind(~element=span, ~clickOnly=true, ~onTrigger=() => {
      switch extractRepo(pathname) {
      | Some(repo) => lookupAndShow(~repo, ~symbol, ~span)
      | None => Console.log2("[elm-peek] no repo in path", pathname)
      }
    })
  })
}

// Delegated click handler. Runs once at script load, captures every click
// in the document, and triggers a lookup if the target's textContent is a
// candidate identifier outside a string/comment. Robust to virtualized
// rendering — works wherever the candidate span actually lives.
let handleDocClick = (ev: Dom.event): unit =>
  switch eventTarget(ev)->Null.toOption {
  | Some(target) =>
    let txt = String.trim(textContent(target))
    // Require the click to land inside a <code> or <pre> ancestor. GitHub
    // wraps every syntax-highlighted token in <code> on both blob and diff
    // views; UI elements (SSO "Continue" buttons, header links, etc.) are
    // never in that context, so this filters out the universe of non-code
    // clicks that happen to have capitalized text content. Without this
    // gate we hijacked any button labeled "Continue", "Sign", "Save", …
    let inCode = target->closest("code, pre")->Null.toOption !== None
    if (
      inCode &&
      candidateRe->RegExp.test(txt) &&
      !TokenScan.isInsideStringOrComment(target)
    ) {
      stopPropagation(ev)
      preventDefault(ev)
      switch extractRepo(pathname) {
      | Some(repo) => lookupAndShow(~repo, ~symbol=txt, ~span=target)
      | None => Console.log2("[elm-peek] no repo in path", pathname)
      }
    }
  | None => ()
  }

let init = (): unit => {
  // Quick guard so we don't run anywhere outside the matches in manifest.
  // The MutationObserver below will pick up lazy-loaded diff containers,
  // so it's fine if `hasElmFile` is false at first paint.
  Console.log2("[elm-peek] content script loaded on", href)

  // Primary: document-level delegated click — robust across views.
  document->addDocClick("click", handleDocClick, {capture: true})

  // Secondary: per-span Hover.bind — handles hover preview when re-enabled
  // and provides a redundant path for views where delegation might miss.
  bindNewSpans()

  // Observe further DOM growth (PR pages lazy-load file contents). We used
  // to gate this on hasElmFile() to avoid scanning on non-Elm pages, but
  // GitHub's redesigned PR view (`/pull/N/changes`) doesn't expose any of
  // the data-tagsearch-path / title / data-path attributes we keyed on, so
  // the gate was always false and bindings never landed. Re-scanning is
  // cheap (regex over all spans, WeakSet dedup) so just always re-scan;
  // the manifest match patterns already scope us to repo-ish pages.
  let observer = makeMutationObserver(() => bindNewSpans())
  observer->observe(documentBody(document), {childList: true, subtree: true})
}

init()
