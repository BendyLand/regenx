package regenx

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

run_cli :: proc(opts: Options) -> int {
	ast, p_err := parse(opts.pattern, opts.ignore_case, context.temp_allocator)
	if p_err != .None {
		fmt.eprintf("regenx: parse error (%v) in pattern %q\n", p_err, opts.pattern)
		return 2
	}
	prog := compile(ast, context.temp_allocator)
	use_color := !opts.no_color && os.is_tty(os.stdout)

	is_stdin := opts.filename == "-"
	if is_stdin && os.is_tty(os.stdin) {
		fmt.eprintln("regenx: '-' requires piped or redirected standard input")
		return 2
	}
	if !is_stdin && os.is_directory(opts.filename) {
		files := make([dynamic]string, context.allocator)
		defer {
			for f in files do delete(f)
			delete(files)
		}
		if err := collect_dir_files(opts.filename, !opts.no_recursive, &files, context.allocator); err != nil {
			fmt.eprintf("regenx: could not read directory %q\n", opts.filename)
			return 2
		}
		total_matches := 0
		for f in files {
			data, f_err := os.read_entire_file(f, context.allocator)
			if f_err != nil {
				delete(data)
				fmt.eprintf("regenx: could not read file %q\n", f)
				continue
			}
			if !is_binary_data(data) {
				total_matches += search_buffer(prog, data, opts, f, true, use_color)
			}
			delete(data)
		}
		return total_matches > 0 ? 0 : 1
	}

	data: []byte
	err: os.Error
	if is_stdin {
		data, err = os.read_entire_file(os.stdin, context.allocator)
	} else {
		data, err = os.read_entire_file(opts.filename, context.allocator)
	}
	if err != nil {
		delete(data)
		if is_stdin {
			fmt.eprintln("regenx: could not read from stdin")
		} else {
			fmt.eprintf("regenx: could not read file %q\n", opts.filename)
		}
		return 2
	}
	defer delete(data)

	match_count := search_buffer(prog, data, opts, opts.filename, false, use_color)
	return match_count > 0 ? 0 : 1
}

is_binary_data :: proc(data: []byte) -> bool {
	check_len := min(len(data), 8192)
	for b in data[:check_len] {
		if b == 0 {
			return true
		}
	}
	return false
}

join_display_path :: proc(dir_path, name: string, allocator := context.allocator) -> string {
	trimmed := strings.trim_right(dir_path, "/")
	if trimmed == "" {
		return fmt.aprintf("/%s", name, allocator = allocator)
	}
	return fmt.aprintf("%s/%s", trimmed, name, allocator = allocator)
}

collect_dir_files :: proc(
	dir_path: string,
	recursive: bool,
	out_files: ^[dynamic]string,
	allocator := context.allocator,
) -> os.Error {
	entries, err := os.read_all_directory_by_path(dir_path, allocator)
	defer os.file_info_slice_delete(entries, allocator)
	if err != nil {
		return err
	}

	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {
		return a.name < b.name
	})

	for entry in entries {
		if entry.name == "." || entry.name == ".." {
			continue
		}
		ftype := entry.type
		if ftype == .Undetermined {
			if fi, st_err := os.stat_do_not_follow_links(entry.fullpath, allocator); st_err == nil {
				ftype = fi.type
				os.file_info_delete(fi, allocator)
			}
		}
		if ftype == .Directory {
			if !recursive || entry.name == ".git" {
				continue
			}
			sub_path := join_display_path(dir_path, entry.name, allocator)
			if sub_err := collect_dir_files(sub_path, recursive, out_files, allocator); sub_err != nil {
				fmt.eprintf("regenx: could not read directory %q\n", sub_path)
			}
			delete(sub_path, allocator)
		} else if ftype == .Regular || (ftype == .Symlink && os.is_file(entry.fullpath)) {
			append(out_files, join_display_path(dir_path, entry.name, allocator))
		}
	}
	return nil
}

@(private = "file")
Line_Prefix :: struct {
	filename:      string,
	show_filename: bool,
	line_num:      int,
	show_line_num: bool,
	use_color:     bool,
}

@(private = "file")
print_line_prefix :: proc(p: Line_Prefix) {
	ANSI_MAGENTA :: "\x1b[35m"
	ANSI_GREEN :: "\x1b[32m"
	ANSI_CYAN :: "\x1b[36m"
	ANSI_RESET :: "\x1b[0m"

	if p.show_filename {
		if p.use_color {
			fmt.printf("%s%s%s:%s", ANSI_MAGENTA, p.filename, ANSI_CYAN, ANSI_RESET)
		} else {
			fmt.printf("%s:", p.filename)
		}
	}
	if p.show_line_num {
		if p.use_color {
			fmt.printf("%s%d%s:%s", ANSI_GREEN, p.line_num, ANSI_CYAN, ANSI_RESET)
		} else {
			fmt.printf("%d:", p.line_num)
		}
	}
}

@(private = "file")
search_buffer :: proc(
	prog: Program,
	data: []byte,
	opts: Options,
	filename: string,
	show_filename: bool,
	use_color: bool,
) -> int {
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
		prefix := Line_Prefix {
			filename      = filename,
			show_filename = show_filename,
			line_num      = line_num,
			show_line_num = opts.line_numbers,
			use_color     = use_color,
		}
		if opts.invert_match || !use_color {
			if opts.only_match && !opts.invert_match {
				print_only_matches(prog, line, caps, prefix)
			} else {
				print_line_prefix(prefix)
				fmt.println(line)
			}
		} else {
			print_highlighted_line(prog, line, caps, opts.only_match, prefix)
		}
	}
	if opts.count_only {
		if show_filename {
			if match_count > 0 {
				if use_color {
					fmt.printf("\x1b[35m%s\x1b[36m:\x1b[0m%d\n", filename, match_count)
				} else {
					fmt.printf("%s:%d\n", filename, match_count)
				}
			}
		} else {
			fmt.println(match_count)
		}
	}
	return match_count
}

@(private = "file")
print_only_matches :: proc(prog: Program, line: string, first_caps: [2]int, prefix: Line_Prefix) {
	caps := first_caps
	for {
		print_line_prefix(prefix)
		fmt.println(line[caps[0]:caps[1]])
		next_pos := max(caps[1], caps[0] + 1)
		if next_pos > len(line) ||
		   !vm_match(prog, line, captures = caps[:], search_from = next_pos) {
			break
		}
	}
}

@(private = "file")
print_highlighted_line :: proc(
	prog: Program,
	line: string,
	first_caps: [2]int,
	only_match: bool,
	prefix: Line_Prefix,
) {
	ANSI_RED :: "\x1b[1;31m"
	ANSI_RESET :: "\x1b[0m"

	caps := first_caps
	printed_up_to := 0

	if !only_match {
		print_line_prefix(prefix)
	}

	for {
		start, end := caps[0], caps[1]
		if only_match {
			print_line_prefix(prefix)
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
		fmt.eprintfln("regenx: %s", args.err_msg)
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
		fmt.eprintln("regenx: --synth requires at least one -p / --pos example")
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
