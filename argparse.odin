package regenx

import "core:fmt"
import "core:strings"

Arg_Error :: enum {
	None,
	Unknown_Flag,
	Missing_Value,
	Too_Many_Args,
}

Run_Mode :: enum {
	Search,
	TUI,
	Synth,
	Help,
}

Options :: struct {
	mode:         Run_Mode,
	err:          Arg_Error,
	err_msg:      string,
	pattern:      string,
	filename:     string,
	ignore_case:  bool,
	invert_match: bool,
	line_numbers: bool,
	count_only:   bool,
	only_match:   bool,
	no_color:     bool,
	unanchored:   bool,
	pos_examples: [dynamic]string,
	neg_examples: [dynamic]string,
	positional:   [dynamic]string,
}

parse_args :: proc(args: []string, allocator := context.allocator) -> (opts: Options) {
	opts.pos_examples = make([dynamic]string, allocator)
	opts.neg_examples = make([dynamic]string, allocator)
	opts.positional = make([dynamic]string, allocator)
	fail :: proc(opts: ^Options, err: Arg_Error, msg: string) -> Options {
		opts.err = err
		opts.err_msg = msg
		return opts^
	}
	explicit_tui := false
	end_of_flags := false
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if end_of_flags || len(arg) < 2 || arg[0] != '-' {
			append(&opts.positional, arg)
			continue
		}
		if arg == "--" {
			end_of_flags = true
			continue
		}
		// Long flags (--flag or --flag=value)
		if strings.has_prefix(arg, "--") {
			name := arg[2:]
			val := ""
			has_eq := false
			if eq := strings.index_byte(name, '='); eq != -1 {
				val = name[eq + 1:]
				name = name[:eq]
				has_eq = true
			}
			switch name {
			case "help":
				opts.mode = .Help
			case "tui", "synth", "interactive":
				explicit_tui = true
			case "ignore-case":
				opts.ignore_case = true
			case "invert-match":
				opts.invert_match = true
			case "line-number":
				opts.line_numbers = true
			case "count":
				opts.count_only = true
			case "only-matching":
				opts.only_match = true
			case "no-color":
				opts.no_color = true
			case "unanchored":
				opts.unanchored = true
			case "pos":
				if !has_eq {
					i += 1
					if i >= len(args) do return fail(&opts, .Missing_Value, "--pos requires an argument")
					val = args[i]
				}
				append(&opts.pos_examples, val)
			case "neg":
				if !has_eq {
					i += 1
					if i >= len(args) do return fail(&opts, .Missing_Value, "--neg requires an argument")
					val = args[i]
				}
				append(&opts.neg_examples, val)
			case:
				return fail(&opts, .Unknown_Flag, fmt.tprintf("unknown flag: --%s", name))
			}
			continue
		}
		// Clustered short flags (-ivn or -p value)
		for j := 1; j < len(arg); j += 1 {
			switch arg[j] {
			case 'h':
				opts.mode = .Help
			case 't':
				explicit_tui = true
			case 'i':
				opts.ignore_case = true
			case 'v':
				opts.invert_match = true
			case 'n':
				opts.line_numbers = true
			case 'c':
				opts.count_only = true
			case 'o':
				opts.only_match = true
			case 'u':
				opts.unanchored = true
			case 'p':
				if j + 1 < len(arg) {
					append(&opts.pos_examples, arg[j + 1:])
				}
				else {
					i += 1
					if i >= len(args) do return fail(&opts, .Missing_Value, "-p requires an argument")
					append(&opts.pos_examples, args[i])
				}
				j = len(arg)
			case 'x':
				if j + 1 < len(arg) {
					append(&opts.neg_examples, arg[j + 1:])
				}
				else {
					i += 1
					if i >= len(args) do return fail(&opts, .Missing_Value, "-x requires an argument")
					append(&opts.neg_examples, args[i])
				}
				j = len(arg)
			case:
				return fail(&opts, .Unknown_Flag, fmt.tprintf("unknown flag: -%c", arg[j]))
			}
		}
	}
	if opts.mode == .Help {
		return opts
	}
	// Resolve final Run_Mode, pattern, and filename
	if explicit_tui || len(opts.pos_examples) > 0 {
		if len(opts.positional) > 1 {
			return fail(&opts, .Too_Many_Args, "expected at most 1 probe file argument")
		}
		if len(opts.positional) == 1 {
			opts.filename = opts.positional[0]
		}
		opts.mode = explicit_tui ? .TUI : .Synth
	}
	else if len(opts.positional) == 0 {
		// Old behavior was to default to TUI with no args.
		// Uncomment this to restore that behavior.
		// if !os.is_tty(os.stdin) {
		// 	return fail(&opts, .Missing_Value, "missing search pattern (use -t to launch TUI)")
		// }
		opts.mode = .Help
	}
	else {
		if len(opts.positional) > 2 {
			return fail(&opts, .Too_Many_Args, "expected at most 1 filename argument")
		}
		opts.mode = .Search
		opts.pattern = opts.positional[0]
		if len(opts.positional) == 2 {
			opts.filename = opts.positional[1]
		}
	}
	return opts
}
