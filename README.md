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
```

---

## Usage

Running `grepback` with no arguments prints the usage summary.

### 1. Regex Search (CLI)

Search is **unanchored** (substring-based) by default and reads from a file or `stdin`:

```bash
# Search a file with line numbers
./grepback -n "\w+(?= :: proc)" parser.odin

# Print only the matched substrings (-o)
./grepback -o "parse_\w+" parser.odin

# Count matching lines (-c) case-insensitively (-i)
./grepback -ic "error" app.log

# Search from stdin
cat server.log | ./grepback "status=5\d\d"
```

### 2. Headless Regex Synthesis (`-p` / `-x`)

Synthesize ranked regex candidates from positive (`-p`) and negative (`-x`) examples. Synthesis defaults to **anchored (`^...$`)** matching; pass `-u` for unanchored substring synthesis:

```bash
# Anchored token synthesis
./grepback -p "user_7" -p "user_42" -p "user_1089" -x "user_admin" -x "guest_42"

# Unanchored log field extraction (-u)
./grepback -u \
  -p "2026-11-17T14:01:02Z status=502 latency=120ms" \
  -p "2026-11-17T14:01:05Z status=504 latency=3000ms" \
  -x "2026-11-17T14:01:08Z status=200 latency=12ms"
```

### 3. Interactive TUI (`-t`)

Launch the TUI standalone or load a file into the `[?] Test Probes` pane for live highlighting:

```bash
# Launch empty TUI
./grepback -t

# Load a file for live regex preview and example selection
./grepback -t parser.odin

# Compose the synthesized regex directly into a CLI search
./grepback -n "$(./grepback -t parser.odin)" parser.odin
```

---

## CLI Flags

| Flag | Description |
| :--- | :--- |
| `-i`, `--ignore-case` | Case-insensitive matching and synthesis |
| `-v`, `--invert-match` | Select non-matching lines (search mode) |
| `-n`, `--line-number` | Prefix output lines with 1-based line numbers |
| `-c`, `--count` | Print only a count of matching lines |
| `-o`, `--only-matching` | Print only the matched parts of each line |
| `--no-color` | Disable ANSI color highlighting |
| `-t`, `--tui`, `--synth` | Launch interactive TUI workbench |
| `-p`, `--pos <str>` | Positive example that must match (repeatable) |
| `-x`, `--neg <str>` | Negative example that must be rejected (repeatable) |
| `-u`, `--unanchored` | Synthesize unanchored substring patterns instead of `^...$` |
| `-h`, `--help` | Show help message and exit |
| `--` | End of command flags |

---

## Interactive TUI Keybindings

| Key | Action |
| :--- | :--- |
| `Tab` / `1` / `2` / `3` | Switch active pane (`[+] Positive`, `[-] Negative`, `[?] Test Probes`) |
| `j` / `k` / `↑` / `↓` | Move selection cursor up/down in the active pane |
| `[` / `]` | Cycle through top synthesized regex candidates |
| `+` / `=` / `p` | Move highlighted item to `[+] Positive` |
| `-` / `_` / `x` | Move highlighted item to `[-] Negative` |
| `?` | Move highlighted item back to `[?] Test Probes` |
| `/` | Regex search forward in the active pane (`Enter` to jump, `Esc` to cancel) |
| `n` / `N` | Jump to next / previous regex search match |
| `a` / `Enter` | Add a new item to the active pane |
| `e` | Edit the highlighted item inline (`←`/`→`/`Home`/`End`/`Backspace`/`Del`) |
| `d` | Delete the highlighted item |
| `u` | Toggle **Anchored (`^...$`)** vs. **Unanchored** synthesis |
| `i` | Toggle **Case-Sensitive** vs. **Case-Insensitive** mode |
| `y` | Print selected regex to `stdout` and quit |
| `q` / `Ctrl+C` | Quit without printing |

---

## Supported Regex Syntax

* **Literals & Escapes:** Standard characters, hex escapes (`\xHH`), control escapes (`\n`, `\r`, `\t`, `\v`, `\f`), and metacharacter escaping (`\.`, `\(`, `\\`, etc.).
* **Character Classes:** `[abc]`, `[a-z]`, negated `[^...]`, `.` (any byte except `\n`), `\d`, `\D`, `\w`, `\W`, `\s`, `\S`.
* **Quantifiers:** `*`, `+`, `?`, `{m}`, `{m,}`, `{m,n}`, plus lazy modifiers (`*?`, `+?`, `??`, `{m,n}?`).
* **Groups & Alternation:** `a|b`, capturing `( ... )`, non-capturing `(?: ... )`.
* **Anchors & Lookarounds:** `^`, `$`, `\b`, `(?= ... )`, `(?! ... )`, `(?<= ... )`, `(?<! ... )` (lookbehinds require fixed-width expressions).

---

## Project Structure

```text
├── main.odin        # Entry point and debug tracking allocator setup
├── argparse.odin    # CLI flag and positional argument parser
├── cli.odin         # Search execution, highlighting, and headless synthesis runner
├── node.odin        # Regex AST node definitions
├── bitmap.odin      # 256-bit ASCII character set operations
├── parser.odin      # Recursive-descent regex parser & fixed-width lookbehind validator
├── print.odin       # Canonical AST-to-regex serializer
├── compiler.odin    # AST-to-bytecode compiler
├── vm.odin          # Backtracking regex VM with capture & lookaround support
├── synth.odin       # Needleman-Wunsch alignment, beam search, and MDL ranker
├── tui.odin         # Raw-mode POSIX terminal UI
├── utils.odin       # CLI usage text
└── ast_test.odin    # Parser round-trip, pretty-printer, and VM unit tests
```