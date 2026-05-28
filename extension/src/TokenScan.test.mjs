// Shim: bun:test discovers files matching .test/.spec patterns. ReScript
// emits TokenScan_test.res → TokenScan_test.res.mjs. This single-line shim
// is the discoverable entry that side-effect-imports the test module.
import "./TokenScan_test.res.mjs";
