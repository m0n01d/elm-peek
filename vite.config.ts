import { defineConfig } from "vite";
import { viteStaticCopy } from "vite-plugin-static-copy";

// Bundle the ReScript-compiled content script into a single IIFE so it can be
// loaded directly by a Manifest V3 content_scripts entry (no ES module loader
// is available in that context without extra ceremony). The manifest is copied
// alongside so `extension/dist/` is the load-ready unpacked extension.
export default defineConfig({
  build: {
    outDir: "extension/dist",
    emptyOutDir: true,
    minify: false,
    sourcemap: true,
    rollupOptions: {
      input: "extension/src/ContentScript.res.mjs",
      output: {
        entryFileNames: "contentScript.js",
        format: "iife",
      },
    },
  },
  plugins: [
    viteStaticCopy({
      targets: [
        {
          src: "extension/manifest.json",
          dest: ".",
          // `vite-plugin-static-copy` preserves source path segments by
          // default, which would yield `extension/dist/extension/manifest.json`.
          // Strip directory segments so the manifest lands beside
          // `contentScript.js` at `extension/dist/manifest.json`.
          rename: {stripBase: true},
        },
      ],
    }),
  ],
});
