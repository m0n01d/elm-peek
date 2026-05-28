// Pure-ish DOM walker that finds capitalized-identifier <span> elements on
// GitHub blob/diff pages, filtering out anything inside a string (`.pl-s`)
// or comment (`.pl-c`) ancestor, and deduplicating against a module-scoped
// WeakSet so the same element is never returned twice.
//
// Per SPEC §"Token detection (extension)" and §"GitHub redesigns":
//   - DO NOT pin to GitHub's container class names — they churn with
//     redesigns. Filter <span> elements by textContent regex.
//   - Skip tokens inside `.pl-s` (string) and `.pl-c` (comment) ancestors.
//   - Use a WeakSet so MutationObserver re-scans don't re-bind the same span.
//
// All selector strings live as named constants in this file so a GitHub
// redesign is a one-file fix.

// --- Selector constants — the only place these strings should appear -----

let spanSelector = "span"
let stringAncestorClass = "pl-s"
let commentAncestorClass = "pl-c"

// Bound on ancestor-chain walks. Six levels is plenty: the worst case in
// GitHub's rendered markup is `<td><span><span>...token</span></span></td>`,
// which is well under this cap. Bounding the walk keeps work O(1) per span.
let ancestorWalkCap = 8

// --- Minimal typed DOM bindings -----------------------------------------

@get external textContent: Dom.element => string = "textContent"
@get external parentElement: Dom.element => Null.t<Dom.element> = "parentElement"

@send
external querySelectorAll: (Dom.document, string) => Dom.nodeList = "querySelectorAll"

// HTMLCollection-ish: Dom.nodeList comes from rescript-react's Dom but we
// only need a length+item view. Keep the binding narrow.
type nodeList = Dom.nodeList
@get external nodeListLength: nodeList => int = "length"
@send external nodeListItem: (nodeList, int) => Null.t<Dom.element> = "item"

// classList.contains(class) — typed, no `{..}`.
type classList
@get external elementClassList: Dom.element => classList = "classList"
@send external classListContains: (classList, string) => bool = "contains"

// --- Regex --------------------------------------------------------------

// Pre-compile once. /^[A-Z][A-Za-z0-9_]*$/.
let candidateRe = RegExp.fromString("^[A-Z][A-Za-z0-9_]*$")

// --- Public API ---------------------------------------------------------

let isCandidateText = (s: string): bool =>
  if s === "" {
    false
  } else {
    candidateRe->RegExp.test(s)
  }

let isInsideStringOrComment = (el: Dom.element): bool => {
  // Walk parentElement chain. The `el` itself can also carry the syntax
  // class (rare but possible), so include it in the check.
  let rec walk = (cur: Null.t<Dom.element>, depth: int): bool =>
    if depth >= ancestorWalkCap {
      false
    } else {
      switch cur->Null.toOption {
      | None => false
      | Some(node) =>
        let cl = node->elementClassList
        if cl->classListContains(stringAncestorClass) || cl->classListContains(commentAncestorClass) {
          true
        } else {
          walk(node->parentElement, depth + 1)
        }
      }
    }
  walk(Null.make(el), 0)
}

// --- WeakSet dedup ------------------------------------------------------
//
// JavaScript's WeakSet doesn't hold strong refs to its keys, which is what
// we want — when a diff cell is GC'd we don't leak. Bind via @new + @send.

type weakSet
@new external makeWeakSet: unit => weakSet = "WeakSet"
@send external weakSetHas: (weakSet, Dom.element) => bool = "has"
@send external weakSetAdd: (weakSet, Dom.element) => weakSet = "add"

let seen = ref(makeWeakSet())

let resetSeen = (): unit => {
  seen := makeWeakSet()
}

let findCandidateSpans = (doc: Dom.document): array<Dom.element> => {
  let list = doc->querySelectorAll(spanSelector)
  let count = list->nodeListLength
  let acc = []
  let i = ref(0)
  while i.contents < count {
    switch list->nodeListItem(i.contents)->Null.toOption {
    | None => ()
    | Some(el) =>
      let txt = el->textContent
      if (
        isCandidateText(txt) &&
          !isInsideStringOrComment(el) &&
          !(seen.contents->weakSetHas(el))
      ) {
        let _ = seen.contents->weakSetAdd(el)
        acc->Array.push(el)
      }
    }
    i := i.contents + 1
  }
  acc
}
