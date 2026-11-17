# grepback

A fast, zero-dependency regex search engine and **Programming-by-Example (PBE) regex synthesizer** written in [Odin](https://odin-lang.org/).

`grepback` pairs a custom bytecode regex VM (with lookaround and capture group support) with an interactive terminal UI and a Minimum Description Length (MDL) synthesis engine that infers human-readable regular expressions from positive and negative examples.

---

## Features

* **Custom Regex Engine & VM:** Hand-rolled recursive-descent parser, AST pretty-printer, 256-bit ASCII character class bitmaps, bytecode compiler, and backtracking VM with zero-width loop protection.
* **Lookarounds & Capture Groups:** Supports positive/negative lookahead (`(?=...)`, `(?!...)`), fixed-width positive/negative lookbehind (`(?<=...)`, `(?<!...)`), capturing groups (`(...)`), non-capturing groups (`(?:...)`), and word boundaries (`\b`).
* **Example-Driven Regex Synthesis:** Combines Needleman-Wunsch sequence alignment, beam search refinement, character class generalization, quantifier collapsing, and negative lookahead injection—ranked by Minimum Description Length (MDL) to avoid over-generalized patterns.
* **Interactive TUI Workbench (`-t`):** Real-time candidate preview against a live probe file, `less`-style regex search (`/`, `n`, `N`), single-key example classification, and shell-composable output (`y`).

---

## Building & Testing

Requires an Odin compiler toolchain (`odin`). On POSIX/Linux systems:

```bash
# Build the binary
odin build . -out:grepback

# Run the unit test suite
odin test .
