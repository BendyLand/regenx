package grepback

import "core:fmt"

print_usage :: proc() {
	fmt.println(
`Usage:
  grepback [flags] <pattern> [<file>]      Search file or stdin for pattern
  grepback [-t | --tui] [<file>]           Launch interactive synthesizer TUI
  grepback -p <str> [-x <str>] [<file>]    Synthesize regex from examples

Search Flags:
  -i, --ignore-case      Case-insensitive matching
  -v, --invert-match     Select non-matching lines
  -n, --line-number      Prefix output lines with line numbers
  -c, --count            Print only a count of matching lines
  -o, --only-matching    Print only the matched parts of a line
      --no-color         Disable ANSI color highlighting

Synthesizer Flags:
  -t, --tui, --synth     Force interactive TUI mode
  -p, --pos <str>        Positive example to match (repeatable)
  -x, --neg <str>        Negative example to reject (repeatable)

General:
  -h, --help             Show this help message and exit
  --                     End of command flags`
	)
}
