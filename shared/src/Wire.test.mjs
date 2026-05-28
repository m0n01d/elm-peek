// Shim: bun:test only discovers files matching .test/.spec patterns, and
// ReScript emits Foo_test.res → Foo_test.res.mjs which doesn't match. This
// single-line file is the discoverable entry; the import side-effects run
// the describe/test blocks declared in Wire_test.res.
import "./Wire_test.res.mjs";
