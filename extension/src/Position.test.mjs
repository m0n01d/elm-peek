// Shim: bun:test discovers files matching .test/.spec patterns. ReScript
// emits Position_test.res → Position_test.res.mjs. This single-line shim
// is the discoverable entry that side-effect-imports the test module.
import "./Position_test.res.mjs";
