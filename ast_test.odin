package regenx

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
}
