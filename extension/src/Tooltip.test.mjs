// Shim: bun:test discovers files matching .test/.spec patterns. ReScript
// emits Tooltip_test.res → Tooltip_test.res.mjs. This shim is the
// discoverable entry that side-effect-imports the test module.
import "./Tooltip_test.res.mjs";
