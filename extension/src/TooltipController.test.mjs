// Shim: bun:test discovers files matching .test/.spec patterns. ReScript
// emits TooltipController_test.res → TooltipController_test.res.mjs.
// This shim is the discoverable entry that side-effect-imports the test.
import "./TooltipController_test.res.mjs";
