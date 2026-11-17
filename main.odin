package grepback

import "core:fmt"
import "core:os"
import "core:mem"

main :: proc() {
	code := 0
	{
		when ODIN_DEBUG {
			track: mem.Tracking_Allocator
			mem.tracking_allocator_init(&track, context.allocator)
			context.allocator = mem.tracking_allocator(&track)
			defer {
				if len(track.allocation_map) > 0 {
					fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
					for _, entry in track.allocation_map {
						fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
					}
				}
				if len(track.bad_free_array) > 0 {
					fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
					for entry in track.bad_free_array {
						fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
					}
				}
				mem.tracking_allocator_destroy(&track)
			}
		}
		code = run()
	}
	os.exit(code)
}

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
