package grepback

import "core:fmt"
import "core:os"
import "core:strings"

run_cli :: proc(opts: Options) -> int {
	ast, p_err := parse(opts.pattern, opts.ignore_case, context.temp_allocator)
	if p_err != .None {
		fmt.eprintf("grepback: parse error (%v) in pattern %q\n", p_err, opts.pattern)
		return 2
	}
	prog := compile(ast, context.temp_allocator)
	data: []byte
	err: os.Error
	if opts.filename == "" {
		data, err = os.read_entire_file(os.stdin, context.allocator)
	} else {
		data, err = os.read_entire_file(opts.filename, context.allocator)
	}
	if err != nil {
		fmt.eprintf("grepback: could not read file %q\n", opts.filename)
		return 2
	}
	defer delete(data)
	use_color := !opts.no_color && os.is_tty(os.stdout)
	match_count := 0
	line_num := 0
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		line_num += 1
		caps: [2]int
		matched := vm_match(prog, line, captures = caps[:], search_from = 0)
		if opts.invert_match {
			matched = !matched
		}
		if !matched {
			continue
		}
		match_count += 1
		if opts.count_only {
			continue
		}
		if opts.line_numbers {
			fmt.printf("%d:", line_num)
		}
		if opts.invert_match || !use_color {
			if opts.only_match && !opts.invert_match {
				print_only_matches(prog, line, caps)
			} else {
				fmt.println(line)
			}
		} else {
			print_highlighted_line(prog, line, caps, opts.only_match)
		}
	}
	if opts.count_only {
		fmt.println(match_count)
	}
	return match_count > 0 ? 0 : 1
}

@(private = "file")
print_only_matches :: proc(prog: Program, line: string, first_caps: [2]int) {
	caps := first_caps
	for {
		fmt.println(line[caps[0]:caps[1]])
		next_pos := max(caps[1], caps[0] + 1)
		if next_pos > len(line) ||
		   !vm_match(prog, line, captures = caps[:], search_from = next_pos) {
			break
		}
	}
}

@(private = "file")
print_highlighted_line :: proc(prog: Program, line: string, first_caps: [2]int, only_match: bool) {
	ANSI_RED :: "\x1b[1;31m"
	ANSI_RESET :: "\x1b[0m"

	caps := first_caps
	printed_up_to := 0

	for {
		start, end := caps[0], caps[1]
		if only_match {
			fmt.printf("%s%s%s\n", ANSI_RED, line[start:end], ANSI_RESET)
		} else {
			fmt.print(line[printed_up_to:start])
			fmt.printf("%s%s%s", ANSI_RED, line[start:end], ANSI_RESET)
			printed_up_to = end
		}

		next_pos := max(end, start + 1)
		if next_pos > len(line) ||
		   !vm_match(prog, line, captures = caps[:], search_from = next_pos) {
			break
		}
	}
	if !only_match {
		fmt.println(line[printed_up_to:])
	}
}

run :: proc() -> int {
	defer free_all(context.temp_allocator)
	args := parse_args(os.args[1:], context.temp_allocator)
	if args.err != .None {
		fmt.eprintfln("grepback: %s", args.err_msg)
		print_usage()
		return 2
	}
	switch args.mode {
	case .Help:
		print_usage()
		return 0
	case .Search:
		return run_cli(args)
	case .Synth:
		return run_headless_synth(args)
	case .TUI:
		return run_tui(args)
	}
	return 0
}

run_headless_synth :: proc(opts: Options) -> int {
	if len(opts.pos_examples) == 0 {
		fmt.eprintln("grepback: --synth requires at least one -p / --pos example")
		return 2
	}
	results := synthesize(
		opts.pos_examples[:],
		opts.neg_examples[:],
		opts.ignore_case,
		anchored = !opts.unanchored,
		top_k = 5,
		allocator = context.temp_allocator,
	)
	for r, idx in results {
		status := r.valid ? "VALID" : "PARTIAL"
		fmt.printf(
			"%d. [%s] +%d/%d -%d (mdl=%d)  %s\n",
			idx + 1,
			status,
			r.pos_hits,
			len(opts.pos_examples),
			r.neg_hits,
			r.mdl_score,
			r.pattern,
		)
	}
	return len(results) > 0 && results[0].valid ? 0 : 1
}
