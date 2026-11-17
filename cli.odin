package grepback

import "core:fmt"
import "core:os"
import "core:strings"

run_cli :: proc(pattern: string, filepath: string) -> int {
	ast, err := parse(pattern, context.temp_allocator)
	if err != .None {
		fmt.eprintf("grepback: parse error (%v) in pattern %q\n", err, pattern)
		return 2
	}

	prog := compile(ast, context.temp_allocator)
	defer free_all(context.temp_allocator)
	data, err2 := os.read_entire_file(filepath, context.allocator)
	if err2 != nil {
		fmt.eprintf("grepback: could not read file %q\n", filepath)
		return 2
	}
	defer delete(data)

	any_match := false
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		caps: [2]int
		if !vm_match(prog, line, captures = caps[:], search_from = 0) {
			continue
		}
		any_match = true
		print_highlighted_line(prog, line, caps)
	}
	return any_match ? 0 : 1
}

@(private = "file")
print_highlighted_line :: proc(prog: Program, line: string, first_caps: [2]int) {
	ANSI_RED :: "\x1b[1;31m"
	ANSI_RESET :: "\x1b[0m"
	caps := first_caps
	printed_up_to := 0
	for {
		start, end := caps[0], caps[1]
		fmt.print(line[printed_up_to:start])
		fmt.printf("%s%s%s", ANSI_RED, line[start:end], ANSI_RESET)
		printed_up_to = end
		// Advance at least 1 byte on zero-width matches (e.g. \b or a*) to prevent loops
		next_pos := max(end, start + 1)
		if next_pos > len(line) || !vm_match(prog, line, captures = caps[:], search_from = next_pos) {
			break
		}
	}
	fmt.println(line[printed_up_to:])
}
