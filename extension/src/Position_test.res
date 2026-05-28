// Pure unit tests for Position.compute. No DOM, no React — all math.

@module("bun:test") external describe: (string, unit => unit) => unit = "describe"
@module("bun:test") external test: (string, unit => unit) => unit = "test"
@module("bun:test") external expect: 'a => 'expectation = "expect"
@send external toBe: ('expectation, 'a) => unit = "toBe"
@send external toBeCloseTo: ('expectation, float) => unit = "toBeCloseTo"

let zeroScroll: Position.viewport = {
  width: 1000.0,
  height: 800.0,
  scrollY: 0.0,
  scrollX: 0.0,
}

let tooltipSize = (480.0, 200.0)

let makeSpan = (~top, ~left, ~width=40.0, ~height=18.0, ()): Position.rect => {
  top,
  left,
  bottom: top +. height,
  right: left +. width,
  width,
  height,
}

describe("Position.compute — default placement (below)", () => {
  test("span near the top → positions BELOW with vertical gap", () => {
    let span = makeSpan(~top=100.0, ~left=200.0, ())
    let anchor = Position.compute(~spanRect=span, ~tooltipSize, ~viewport=zeroScroll)
    // Below: top = span.bottom + verticalGap
    expect(anchor.top)->toBeCloseTo(100.0 +. 18.0 +. 4.0)
    expect(anchor.left)->toBeCloseTo(200.0)
  })
})

describe("Position.compute — flip above when off-screen below", () => {
  test("span near the bottom → flips ABOVE", () => {
    // Viewport height 800; span.bottom = 790 + 18 = is too close.
    let span = makeSpan(~top=700.0, ~left=100.0, ())
    let anchor = Position.compute(~spanRect=span, ~tooltipSize, ~viewport=zeroScroll)
    // span.bottom = 718; 718 + 4 + 200 = 922 > 800 → flip above
    // above top = span.top - verticalGap - tooltipHeight = 700 - 4 - 200 = 496
    expect(anchor.top)->toBeCloseTo(700.0 -. 4.0 -. 200.0)
  })

  test("viewport smaller than tooltip → clamps top to topPadding (CSS max-height handles overflow)", () => {
    let tinyViewport: Position.viewport = {
      width: 1000.0,
      height: 100.0,
      scrollY: 0.0,
      scrollX: 0.0,
    }
    let span = makeSpan(~top=10.0, ~left=10.0, ())
    let anchor = Position.compute(~spanRect=span, ~tooltipSize, ~viewport=tinyViewport)
    // Below overflows (28 + 200 > 100). Above doesn't fit (10-4-200 = -194).
    // With vertical clamp, top is pinned to topPadding so the user can
    // still see the top of the tooltip; CSS max-height makes the body
    // scrollable.
    expect(anchor.top)->toBeCloseTo(8.0)
  })
})

describe("Position.compute — horizontal alignment", () => {
  test("span on right half → tooltip's right edge aligns with span's right", () => {
    // Viewport 1000, half = 500. Span at left=900 (width=40, right=940)
    // is on the right half, so the tooltip right-aligns:
    //   desired left = span.right - tooltipWidth = 940 - 480 = 460
    let span = makeSpan(~top=100.0, ~left=900.0, ())
    let anchor = Position.compute(~spanRect=span, ~tooltipSize, ~viewport=zeroScroll)
    expect(anchor.left)->toBeCloseTo(940.0 -. 480.0)
  })

  test("span on left half → tooltip's left edge aligns with span's left", () => {
    let span = makeSpan(~top=100.0, ~left=200.0, ())
    let anchor = Position.compute(~spanRect=span, ~tooltipSize, ~viewport=zeroScroll)
    expect(anchor.left)->toBeCloseTo(200.0)
  })

  test("very narrow viewport keeps tooltip flush to left edge", () => {
    let narrow: Position.viewport = {
      width: 400.0,
      height: 800.0,
      scrollY: 0.0,
      scrollX: 0.0,
    }
    let span = makeSpan(~top=100.0, ~left=300.0, ())
    let anchor = Position.compute(~spanRect=span, ~tooltipSize, ~viewport=narrow)
    // max left = 400 - 8 - 480 = -88. Clamped up to leftPadding = 8.
    expect(anchor.left)->toBeCloseTo(8.0)
  })
})

describe("Position.compute — scroll offsets", () => {
  test("scrolled viewport adds scroll offsets to output coords", () => {
    let scrolled: Position.viewport = {
      width: 1000.0,
      height: 800.0,
      scrollY: 250.0,
      scrollX: 30.0,
    }
    let span = makeSpan(~top=100.0, ~left=200.0, ())
    let anchor = Position.compute(~spanRect=span, ~tooltipSize, ~viewport=scrolled)
    expect(anchor.top)->toBeCloseTo(100.0 +. 18.0 +. 4.0 +. 250.0)
    expect(anchor.left)->toBeCloseTo(200.0 +. 30.0)
  })
})
