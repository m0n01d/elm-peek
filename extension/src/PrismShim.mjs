// Minimal shim so Tooltip.res can call into Prism without ReScript needing
// to bind two separate imports (the core + the side-effect-only language
// registration). Keep the surface area tiny: one typed function in, one
// HTML string out.
import Prism from "prismjs";
import "prismjs/components/prism-elm";

export const highlightElm = (code) => Prism.highlight(code, Prism.languages.elm, "elm");
