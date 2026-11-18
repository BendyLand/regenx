package regenx

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
test_pretty_print :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	alloc := context.temp_allocator
	// Build: a(?:b|c)+
	alt := new_node(Alt_Node{branches = {new_node('b', alloc), new_node('c', alloc)}}, alloc)
	rep := new_node(Repeat_Node{child = alt, min = 1, max = -1, greedy = true}, alloc)
	root := new_node([]^Node{new_node('a', alloc), rep}, alloc)
	got := ast_to_string(root, alloc)
	testing.expect_value(t, got, "a(?:b|c)+")
}

@(test)
test_parser_round_trip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	alloc := context.temp_allocator
	cases := []string{`^foo_(?!admin$)[a-z]+$`, `(?<=foo|bar)\d{2,4}?`, `a(?:b|c)*`, `[^A-Z]\w+\b`}
	for pat in cases {
		ast, err := parse(pat, false, alloc)
		testing.expect_value(t, err, Parse_Error.None)
		testing.expect_value(t, ast_to_string(ast, alloc), pat)
	}
	_, bad_lb := parse(`(?<=a+)foo`, false, alloc)
	testing.expect_value(t, bad_lb, Parse_Error.Variable_Length_Lookbehind)
}

@(test)
test_vm_execution :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	alloc := context.temp_allocator
	// Negative lookahead from spec
	ast1, err1 := parse(`^foo_(?!admin$)[a-z]+$`, false, alloc)
	testing.expect_value(t, err1, Parse_Error.None)
	prog1 := compile(ast1, alloc)
	testing.expect(t, vm_match(prog1, "foo_user"))
	testing.expect(t, vm_match(prog1, "foo_guest"))
	testing.expect(t, !vm_match(prog1, "foo_admin"))
	testing.expect(t, vm_match(prog1, "foo_adminx"))
	// Fixed-width lookbehind + capture group
	ast2, err2 := parse(`(?<=\$)\d+\.\d{2}`, false, alloc)
	testing.expect_value(t, err2, Parse_Error.None)
	prog2 := compile(ast2, alloc)
	caps: [2]int
	testing.expect(t, vm_match(prog2, "Total: $42.95 USD", captures = caps[:]))
	testing.expect_value(t, caps[0], 8) // starts right after '$'
	testing.expect_value(t, caps[1], 13) // ends after '5'
}

@(test)
test_parse_args_stdin :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	alloc := context.temp_allocator

	// Explicit '-' target for CLI search
	opts1 := parse_args([]string{"-in", "error", "-"}, alloc)
	testing.expect_value(t, opts1.err, Arg_Error.None)
	testing.expect_value(t, opts1.mode, Run_Mode.Search)
	testing.expect_value(t, opts1.ignore_case, true)
	testing.expect_value(t, opts1.line_numbers, true)
	testing.expect_value(t, opts1.pattern, "error")
	testing.expect_value(t, opts1.filename, "-")

	// Searching for literal '-' pattern against stdin '-'
	opts2 := parse_args([]string{"-", "-"}, alloc)
	testing.expect_value(t, opts2.err, Arg_Error.None)
	testing.expect_value(t, opts2.mode, Run_Mode.Search)
	testing.expect_value(t, opts2.pattern, "-")
	testing.expect_value(t, opts2.filename, "-")

	// Searching for literal '-' pattern against a file
	opts3 := parse_args([]string{"-", "parser.odin"}, alloc)
	testing.expect_value(t, opts3.err, Arg_Error.None)
	testing.expect_value(t, opts3.mode, Run_Mode.Search)
	testing.expect_value(t, opts3.pattern, "-")
	testing.expect_value(t, opts3.filename, "parser.odin")

	// Explicit '-' target for interactive TUI
	opts4 := parse_args([]string{"-t", "-"}, alloc)
	testing.expect_value(t, opts4.err, Arg_Error.None)
	testing.expect_value(t, opts4.mode, Run_Mode.TUI)
	testing.expect_value(t, opts4.filename, "-")

	// --no-recursive flag with directory target
	opts5 := parse_args([]string{"--no-recursive", "proc", "src/"}, alloc)
	testing.expect_value(t, opts5.err, Arg_Error.None)
	testing.expect_value(t, opts5.mode, Run_Mode.Search)
	testing.expect_value(t, opts5.no_recursive, true)
	testing.expect_value(t, opts5.pattern, "proc")
	testing.expect_value(t, opts5.filename, "src/")

	// Missing target path (single positional arg) should fail instead of hanging on stdin
	opts6 := parse_args([]string{"only_pattern"}, alloc)
	testing.expect_value(t, opts6.err, Arg_Error.Missing_Value)

	// Bare '-' without pattern should fail
	opts7 := parse_args([]string{"-"}, alloc)
	testing.expect_value(t, opts7.err, Arg_Error.Missing_Value)

	// Search flag with no positional args should fail
	opts8 := parse_args([]string{"-n"}, alloc)
	testing.expect_value(t, opts8.err, Arg_Error.Missing_Value)
}

@(test)
test_directory_collection :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	alloc := context.temp_allocator

	tmp_dir, dir_err := os.make_directory_temp("", "regenx_dir_test_*", alloc)
	testing.expect_value(t, dir_err, nil)
	defer _ = os.remove_all(tmp_dir)

	sub_dir := fmt.tprintf("%s/nested", tmp_dir)
	deep_dir := fmt.tprintf("%s/nested/deep", tmp_dir)
	git_dir := fmt.tprintf("%s/.git", tmp_dir)
	testing.expect_value(t, os.make_directory_all(deep_dir), nil)
	testing.expect_value(t, os.make_directory_all(git_dir), nil)

	top_file := fmt.tprintf("%s/alpha.txt", tmp_dir)
	sub_file := fmt.tprintf("%s/beta.txt", sub_dir)
	deep_file := fmt.tprintf("%s/gamma.txt", deep_dir)
	git_file := fmt.tprintf("%s/HEAD", git_dir)

	testing.expect_value(t, os.write_entire_file(top_file, "hello top\n"), nil)
	testing.expect_value(t, os.write_entire_file(sub_file, "hello sub\n"), nil)
	testing.expect_value(t, os.write_entire_file(deep_file, "hello deep\n"), nil)
	testing.expect_value(t, os.write_entire_file(git_file, "ref: refs/heads/main\n"), nil)

	// Default recursive collection (skips .git, descends into nested & deep)
	rec_files := make([dynamic]string, alloc)
	testing.expect_value(t, collect_dir_files(tmp_dir, true, &rec_files, alloc), nil)
	testing.expect_value(t, len(rec_files), 3)
	if len(rec_files) == 3 {
		testing.expect_value(t, rec_files[0], top_file)
		testing.expect_value(t, rec_files[1], sub_file)
		testing.expect_value(t, rec_files[2], deep_file)
	}

	// Non-recursive collection (--no-recursive)
	flat_files := make([dynamic]string, alloc)
	testing.expect_value(t, collect_dir_files(tmp_dir, false, &flat_files, alloc), nil)
	testing.expect_value(t, len(flat_files), 1)
	if len(flat_files) == 1 {
		testing.expect_value(t, flat_files[0], top_file)
	}

	// Binary detection
	testing.expect(t, !is_binary_data(transmute([]byte)string("plain text\n")))
	testing.expect(t, is_binary_data([]byte{'E', 'L', 'F', 0, 1, 2}))
}
