// Pure positioning math for the elm-peek tooltip. No React, no DOM
// mutations — just numbers in, numbers out so tests can drive every
// boundary case without spinning up happy-dom.
//
// Default: position the tooltip BELOW the span. If the tooltip would
// overflow the bottom of the viewport, flip it ABOVE. If it would
// overflow the right edge, clamp leftward so the right edge sits at
// `viewport.width - rightPadding`.
//
// Output is in document coordinates (i.e. includes the viewport's
// current scroll offsets). The caller can use this directly as
// `style.top` / `style.left` on a `position: absolute` host node that
// is a child of `document.body`.

type rect = {
  top: float,
  left: float,
  bottom: float,
  right: float,
  width: float,
  height: float,
}

type viewport = {
  width: float,
  height: float,
  scrollY: float,
  scrollX: float,
}

type anchor = {
  top: float,
  left: float,
}

// Padding between the span and the tooltip edge.
let verticalGap = 4.0

// Edge paddings so the tooltip doesn't kiss the viewport.
let rightPadding = 8.0
let leftPadding = 8.0
let topPadding = 8.0
let bottomPadding = 8.0

let compute = (~spanRect: rect, ~tooltipSize: (float, float), ~viewport: viewport): anchor => {
  let (tooltipWidth, tooltipHeight) = tooltipSize

  // Viewport-relative candidate positions (no scroll yet).
  let belowTopVp = spanRect.bottom +. verticalGap
  let aboveTopVp = spanRect.top -. verticalGap -. tooltipHeight

  // Flip to above if below would overflow the viewport bottom, but only
  // if above has room. Otherwise stay below (better to scroll than be
  // off-screen entirely).
  let placeAbove = {
    let belowOverflows = belowTopVp +. tooltipHeight > viewport.height
    let aboveFits = aboveTopVp >= 0.0
    belowOverflows && aboveFits
  }

  let desiredTopVp = placeAbove ? aboveTopVp : belowTopVp

  // Vertical clamp: keep the tooltip's top/bottom within the viewport.
  // If it's too tall to fit even with clamping, leave the top at topPadding
  // so the user can scroll the tooltip's own overflow (CSS max-height
  // handles that). Caller controls box-sizing.
  let maxTopVp = viewport.height -. bottomPadding -. tooltipHeight
  let clampedTopVp = if desiredTopVp > maxTopVp {
    maxTopVp
  } else {
    desiredTopVp
  }
  let topVp = if clampedTopVp < topPadding {
    topPadding
  } else {
    clampedTopVp
  }

  // Horizontal anchor:
  //   - Span on the LEFT half of the viewport → tooltip's left edge aligns
  //     with the span's left (tooltip grows rightward).
  //   - Span on the RIGHT half → tooltip's RIGHT edge aligns with the
  //     span's right (tooltip grows leftward). Visually symmetric — the
  //     tooltip never crosses the page midline away from its target.
  // Then clamp to [leftPadding, viewport.width - rightPadding].
  let onRightHalf = spanRect.left >= viewport.width /. 2.0
  let desiredLeftVp = onRightHalf
    ? spanRect.right -. tooltipWidth
    : spanRect.left
  let maxLeftVp = viewport.width -. rightPadding -. tooltipWidth
  let clampedLeftVp = if desiredLeftVp > maxLeftVp {
    maxLeftVp
  } else {
    desiredLeftVp
  }
  let leftVp = if clampedLeftVp < leftPadding {
    leftPadding
  } else {
    clampedLeftVp
  }

  // Translate to document coordinates so the caller can assign without
  // worrying about scroll offsets.
  {
    top: topVp +. viewport.scrollY,
    left: leftVp +. viewport.scrollX,
  }
}
