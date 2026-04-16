/**
 * @type {import("lint-staged").Configuration}
 */
module.exports = {
    "*.{json,svg,yml}": "bunx prettier --cache --write",
    "*.md": "mdformat",
    "*.sol": () => "just full-write",
};
