package grepback

import "core:fmt"
import "core:os"
import "core:mem"

main :: proc() {
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
	// Runs FIRST (wipes temp_allocator before the tracking check)
	defer free_all(context.temp_allocator)
	alloc := context.temp_allocator
	if len(os.args) >= 3 {
		os.exit(run_cli(os.args[1], os.args[2]))
	}
	else {
		print_usage()
	}
}

print_usage :: proc() {
	fmt.println(
		"""
		Usage:
		grepback [flags] <pattern|target> [<file>]
		Flags:
		-i — Start interactive mode.
		"""
	)
}
