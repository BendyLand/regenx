package regenx

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

foreign import libc "system:c"

@(private = "file")
Winsize :: struct {
	ws_row:    c.ushort,
	ws_col:    c.ushort,
	ws_xpixel: c.ushort,
	ws_ypixel: c.ushort,
}

@(private = "file")
TIOCGWINSZ :: 0x5413 // Linux x86_64 / arm64

@(private = "file")
foreign libc {
	ioctl :: proc(fd: c.int, request: c.ulong, argp: rawptr) -> c.int ---
}

@(private = "file")
Pane :: enum {
	Pos,
	Neg,
	Probe,
}

@(private = "file")
Edit_Mode :: enum {
	None,
	Add_Item,
	Edit_Item,
	Search,
}

@(private = "file")
TUI_State :: struct {
	pos_list:       [dynamic]string,
	neg_list:       [dynamic]string,
	probe_list:     [dynamic]string,
	active_pane:    Pane,
	cursor:         [Pane]int,
	selected_cand:  int,
	results:        []Synth_Result,
	anchored:       bool,
	ignore_case:    bool,
	edit_buf:       [dynamic]u8,
	edit_mode:      Edit_Mode,
	edit_cursor:    int,
	search_query:   string,
	search_status:  string,
	output_on_exit: bool,
	tty_in:         ^os.File,
}

run_tui :: proc(opts: Options) -> int {
	if !os.is_tty(os.stdout) {
		fmt.eprintln("regenx: interactive TUI requires a terminal (TTY)")
		return 2
	}

	probe_data: []byte
	has_probe_data := false
	read_stdin := opts.filename == "-" || (opts.filename == "" && !os.is_tty(os.stdin))
	if read_stdin {
		err: os.Error
		probe_data, err = os.read_entire_file(os.stdin, context.temp_allocator)
		if err != nil {
			fmt.eprintln("regenx: could not read from stdin")
			return 2
		}
		has_probe_data = true
	} else if opts.filename != "" {
		err: os.Error
		probe_data, err = os.read_entire_file(opts.filename, context.temp_allocator)
		if err == nil {
			has_probe_data = true
		}
	}

	tty_in := os.stdin
	tty_fd: posix.FD = posix.STDIN_FILENO
	if read_stdin || !os.is_tty(os.stdin) {
		opened, open_err := os.open("/dev/tty")
		if open_err != nil {
			fmt.eprintln("regenx: interactive TUI requires a terminal (TTY)")
			return 2
		}
		tty_in = opened
		tty_fd = posix.FD(os.fd(opened))
	}
	defer if tty_in != os.stdin {
		os.close(tty_in)
	}

	orig_termios: posix.termios
	if posix.tcgetattr(tty_fd, &orig_termios) != .OK {
		fmt.eprintln("regenx: failed to read terminal attributes")
		return 2
	}

	raw := orig_termios
	raw.c_iflag &~= {.BRKINT, .ICRNL, .INPCK, .ISTRIP, .IXON}
	raw.c_oflag &~= {.OPOST}
	raw.c_cflag |= {.CS8}
	raw.c_lflag &~= {.ECHO, .ICANON, .IEXTEN, .ISIG}
	raw.c_cc[.VMIN] = 1
	raw.c_cc[.VTIME] = 0

	if posix.tcsetattr(tty_fd, .TCSAFLUSH, &raw) != .OK {
		fmt.eprintln("regenx: failed to enable raw terminal mode")
		return 2
	}
	chosen_out: string
	defer if len(chosen_out) > 0 {
		// Print after alternate screen restore so shell command substitution captures it cleanly
		fmt.println(chosen_out)
		delete(chosen_out)
	}
	// Switch to alternate screen buffer and hide cursor; restore everything on exit
	fmt.print("\x1b[?1049h\x1b[?25l")
	defer {
		fmt.print("\x1b[?25h\x1b[?1049l")
		posix.tcsetattr(tty_fd, .TCSAFLUSH, &orig_termios)
	}
	state := TUI_State {
		anchored    = !opts.unanchored,
		ignore_case = opts.ignore_case,
		tty_in      = tty_in,
	}
	defer {
		for s in state.pos_list do delete(s)
		for s in state.neg_list do delete(s)
		for s in state.probe_list do delete(s)
		delete(state.pos_list)
		delete(state.neg_list)
		delete(state.probe_list)
		delete(state.edit_buf)
		delete(state.search_query)
		free_results(&state)
	}
	for s in opts.pos_examples do append(&state.pos_list, strings.clone(s))
	for s in opts.neg_examples do append(&state.neg_list, strings.clone(s))
	if has_probe_data {
		it := string(probe_data)
		for line in strings.split_lines_iterator(&it) {
			if len(line) > 0 {
				append(&state.probe_list, strings.clone(line))
			}
		}
	}
	recompute_synth(&state)
	for {
		render_tui(&state)
		if !handle_input(&state) {
			break
		}
	}
	if state.output_on_exit && len(state.results) > 0 {
		chosen_out = strings.clone(
			state.results[min(state.selected_cand, len(state.results) - 1)].pattern,
		)
	}
	return 0
}

@(private = "file")
free_results :: proc(s: ^TUI_State) {
	for r in s.results {
		delete(r.pattern)
	}
	delete(s.results)
	s.results = nil
}

@(private = "file")
recompute_synth :: proc(s: ^TUI_State) {
	free_results(s)
	defer free_all(context.temp_allocator)
	if len(s.pos_list) == 0 {
		s.selected_cand = 0
		return
	}
	s.results = synthesize(
		s.pos_list[:],
		s.neg_list[:],
		ignore_case = s.ignore_case,
		anchored = s.anchored,
		top_k = 5,
		allocator = context.allocator,
	)
	if s.selected_cand >= len(s.results) {
		s.selected_cand = max(0, len(s.results) - 1)
	}
}

@(private = "file")
get_term_size :: proc() -> (rows, cols: int) {
	ws: Winsize
	if ioctl(c.int(posix.STDOUT_FILENO), TIOCGWINSZ, &ws) == 0 && ws.ws_row > 0 && ws.ws_col > 0 {
		return int(ws.ws_row), int(ws.ws_col)
	}
	return 24, 80
}

@(private = "file")
render_tui :: proc(s: ^TUI_State) {
	defer free_all(context.temp_allocator)
	rows, cols := get_term_size()
	b := strings.builder_make(context.temp_allocator)
	// Move home & clear screen
	strings.write_string(&b, "\x1b[H\x1b[2J")
	// Header bar
	mode_str := s.anchored ? "ANCHORED (^...$)" : "UNANCHORED"
	case_str := s.ignore_case ? "CASE-INSENSITIVE" : "CASE-SENSITIVE"
	fmt.sbprintf(
		&b,
		"\x1b[1;36m regenx TUI\x1b[0m  |  \x1b[33m%s\x1b[0m  |  \x1b[33m%s\x1b[0m\r\n",
		mode_str,
		case_str,
	)
	write_rule(&b, cols)
	// Synthesized Candidates Section
	strings.write_string(&b, "\x1b[1m Synthesized Candidates ([ / ] to select):\x1b[0m\r\n")
	if len(s.results) == 0 {
		strings.write_string(
			&b,
			"   \x1b[90m(add at least one [+] positive example to synthesize)\x1b[0m\r\n",
		)
	}
	else {
		for r, idx in s.results {
			pointer := (idx == s.selected_cand) ? "\x1b[1;32m>\x1b[0m" : " "
			badge := r.valid ? "\x1b[32mVALID\x1b[0m" : "\x1b[33mPART \x1b[0m"
			fmt.sbprintf(
				&b,
				" %s %d. [%s] +%d/%d -%d (mdl=%d)  \x1b[1m%s\x1b[0m\r\n",
				pointer,
				idx + 1,
				badge,
				r.pos_hits,
				len(s.pos_list),
				r.neg_hits,
				r.mdl_score,
				r.pattern,
			)
		}
	}
	write_rule(&b, cols)
	// Compile active pattern for live Probe highlighting
	has_prog := false
	prog: Program
	if len(s.results) > 0 {
		pat := s.results[s.selected_cand].pattern
		if ast, err := parse(pat, s.ignore_case, context.temp_allocator); err == .None {
			prog = compile(ast, context.temp_allocator)
			has_prog = true
		}
	}
	// Render the 3 Example Lists (account for wrapped candidate lines so layout never overflows)
	cand_rows := 0
	if len(s.results) == 0 {
		cand_rows = 1
	}
	else {
		for r, idx in s.results {
			prefix := fmt.tprintf(
				"   %d. [VALID] +%d/%d -%d (mdl=%d)  ",
				idx + 1,
				r.pos_hits,
				len(s.pos_list),
				r.neg_hits,
				r.mdl_score,
			)
			vis_len := len(prefix) + len(r.pattern)
			cand_rows += max(1, (vis_len + max(1, cols) - 1) / max(1, cols))
		}
	}
	fixed_rows := 10 + cand_rows // header, 2 rules, cand header, 3 pane headers, spacer, footer
	avail_rows := max(4, rows - fixed_rows)
	pos_budget := min(max(1, len(s.pos_list)), max(2, avail_rows / 5))
	neg_budget := min(max(1, len(s.neg_list)), max(2, avail_rows / 5))
	probe_budget := max(2, avail_rows - pos_budget - neg_budget)
	render_pane(
		&b,
		s,
		.Pos,
		"[+] Positive (must match)",
		"\x1b[32m",
		pos_budget,
		false,
		has_prog,
		prog,
		cols,
	)
	render_pane(
		&b,
		s,
		.Neg,
		"[-] Negative (must reject)",
		"\x1b[31m",
		neg_budget,
		false,
		has_prog,
		prog,
		cols,
	)
	render_pane(
		&b,
		s,
		.Probe,
		"[?] Test Probes (live preview)",
		"\x1b[34m",
		probe_budget,
		true,
		has_prog,
		prog,
		cols,
	)
	// Footer / Edit Prompt
	fmt.sbprintf(&b, "\x1b[%d;1H\x1b[2K", max(1, rows - 1))
	switch s.edit_mode {
	case .Add_Item, .Edit_Item:
		write_edit_prompt(
			&b,
			" INPUT > ",
			string(s.edit_buf[:]),
			s.edit_cursor,
			"  (Enter=save, Esc=cancel)",
		)
	case .Search:
		write_edit_prompt(
			&b,
			" /",
			string(s.edit_buf[:]),
			s.edit_cursor,
			"  (Enter=search, Esc=cancel)",
		)
	case .None:
		if s.search_status != "" {
			fmt.sbprintf(&b, "\x1b[1;31m %s \x1b[0m  ", s.search_status)
		}
		strings.write_string(
			&b,
			"\x1b[7m Tab/1-3:Pane  j/k:Move  /:Find  n/N:Next  a:Add  e:Edit  d:Del  +/p:Pos  -/x:Neg  ?:Probe  u:Anchor  i:Case  y:Print&Quit  q:Quit \x1b[0m",
		)
	}
	os.write_string(os.stdout, strings.to_string(b))
}

@(private = "file")
render_pane :: proc(
	b: ^strings.Builder,
	s: ^TUI_State,
	pane: Pane,
	title: string,
	color: string,
	max_items: int,
	highlight_matches: bool,
	has_prog: bool,
	prog: Program,
	cols: int,
) {
	items := get_pane_list(s, pane)^
	active := (s.active_pane == pane) && (s.edit_mode == .None || s.edit_mode == .Edit_Item)
	header_style := active ? "\x1b[1;4m" : ""
	fmt.sbprintf(b, " %s%s%s (%d)\x1b[0m\r\n", color, header_style, title, len(items))
	if len(items) == 0 {
		strings.write_string(b, "   (empty)\r\n")
		return
	}

	max_text := max(10, cols - 6)
	cur := clamp(s.cursor[pane], 0, len(items) - 1)
	start := 0
	if cur >= max_items {
		start = cur - max_items + 1
	}
	end := min(len(items), start + max_items)

	for i := start; i < end; i += 1 {
		item := items[i]
		disp := len(item) > max_text ? item[:max_text] : item
		marker := (active && i == cur) ? "\x1b[1;36m>\x1b[0m" : " "

		if highlight_matches && has_prog {
			caps: [2]int
			if vm_match(prog, item, captures = caps[:], anchored = s.anchored) {
				c0 := min(caps[0], len(disp))
				c1 := min(caps[1], len(disp))
				fmt.sbprintf(
					b,
					" %s \x1b[32m✓\x1b[0m %s\x1b[1;31m%s\x1b[0m%s\r\n",
					marker,
					disp[:c0],
					disp[c0:c1],
					disp[c1:],
				)
			} else {
				fmt.sbprintf(b, " %s · %s\r\n", marker, disp)
			}
		} else {
			fmt.sbprintf(b, " %s %s\r\n", marker, disp)
		}
	}
}

@(private = "file")
write_rule :: proc(b: ^strings.Builder, cols: int) {
	for _ in 0 ..< min(cols, 120) {
		strings.write_byte(b, '-')
	}
	strings.write_string(b, "\r\n")
}

@(private = "file")
get_pane_list :: proc(s: ^TUI_State, pane: Pane) -> ^[dynamic]string {
	switch pane {
	case .Pos:
		return &s.pos_list
	case .Neg:
		return &s.neg_list
	case .Probe:
		return &s.probe_list
	}
	return &s.pos_list
}

@(private = "file")
handle_input :: proc(s: ^TUI_State) -> bool {
	buf: [8]u8
	n, err := os.read(s.tty_in, buf[:])
	if err != nil || n <= 0 {
		return false
	}
	key := buf[:n]
	if s.edit_mode != .None {
		return handle_edit_key(s, key)
	}
	// Arrow escape sequences
	if len(key) >= 3 && key[0] == 0x1b && key[1] == '[' {
		switch key[2] {
		case 'A':
			move_cursor(s, -1)
		case 'B':
			move_cursor(s, 1)
		}
		return true
	}
	switch key[0] {
	case 'q', 3:
		// 'q' or Ctrl+C
		return false
	case 'y':
		s.output_on_exit = true
		return false
	case '\t':
		s.active_pane = Pane((int(s.active_pane) + 1) % 3)
	case '1':
		s.active_pane = .Pos
	case '2':
		s.active_pane = .Neg
	case '3':
		s.active_pane = .Probe
	case 'j':
		move_cursor(s, 1)
	case 'k':
		move_cursor(s, -1)
	case '[':
		if len(s.results) > 0 {
			s.selected_cand = (s.selected_cand + len(s.results) - 1) % len(s.results)
		}
	case ']':
		if len(s.results) > 0 {
			s.selected_cand = (s.selected_cand + 1) % len(s.results)
		}
	case 'u':
		s.anchored = !s.anchored
		recompute_synth(s)
	case 'i':
		s.ignore_case = !s.ignore_case
		recompute_synth(s)
	case 'a', '\r', '\n':
		clear(&s.edit_buf)
		s.edit_cursor = 0
		s.edit_mode = .Add_Item
	case 'e':
		list := get_pane_list(s, s.active_pane)^
		if len(list) > 0 {
			cur := clamp(s.cursor[s.active_pane], 0, len(list) - 1)
			clear(&s.edit_buf)
			append(&s.edit_buf, ..transmute([]u8)list[cur])
			s.edit_cursor = len(s.edit_buf)
			s.edit_mode = .Edit_Item
		}
	case '/':
		clear(&s.edit_buf)
		s.edit_cursor = 0
		s.edit_mode = .Search
	case 'd':
		list := get_pane_list(s, s.active_pane)
		if len(list^) > 0 {
			cur := clamp(s.cursor[s.active_pane], 0, len(list^) - 1)
			delete(list^[cur])
			ordered_remove(list, cur)
			s.cursor[s.active_pane] = clamp(cur, 0, max(0, len(list^) - 1))
			recompute_synth(s)
		}
	case '+', '=', 'p':
		move_item_to_pane(s, .Pos)
	case '-', '_', 'x':
		move_item_to_pane(s, .Neg)
	case '?':
		move_item_to_pane(s, .Probe)
	case 'n':
		jump_to_match(s, 1)
	case 'N':
		jump_to_match(s, -1)
	}
	return true
}

@(private = "file")
move_item_to_pane :: proc(s: ^TUI_State, target: Pane) {
	if s.active_pane == target {
		return
	}
	src := get_pane_list(s, s.active_pane)
	if len(src^) == 0 {
		return
	}
	cur := clamp(s.cursor[s.active_pane], 0, len(src^) - 1)
	val := src^[cur]
	ordered_remove(src, cur)
	s.cursor[s.active_pane] = clamp(cur, 0, max(0, len(src^) - 1))
	dst := get_pane_list(s, target)
	append(dst, val)
	s.cursor[target] = len(dst^) - 1
	recompute_synth(s)
}

@(private = "file")
handle_edit_key :: proc(s: ^TUI_State, key: []u8) -> bool {
	// Multi-byte CSI escape sequences (Left, Right, Home, End, Delete)
	if len(key) >= 3 && key[0] == 0x1b && key[1] == '[' {
		switch key[2] {
		case 'C':
			// Right arrow
			s.edit_cursor = min(len(s.edit_buf), s.edit_cursor + 1)
		case 'D':
			// Left arrow
			s.edit_cursor = max(0, s.edit_cursor - 1)
		case 'H':
			// Home
			s.edit_cursor = 0
		case 'F':
			// End
			s.edit_cursor = len(s.edit_buf)
		case '1':
			if len(key) >= 4 && key[3] == '~' do s.edit_cursor = 0
		case '3':
			if len(key) >= 4 && key[3] == '~' && s.edit_cursor < len(s.edit_buf) {
				ordered_remove(&s.edit_buf, s.edit_cursor)
			}
		case '4':
			if len(key) >= 4 && key[3] == '~' do s.edit_cursor = len(s.edit_buf)
		}
		return true
	}

	switch key[0] {
	case 0x1b:
		// Bare Esc cancels edit
		if len(key) == 1 {
			s.edit_mode = .None
		}
	case '\r', '\n':
		mode := s.edit_mode
		s.edit_mode = .None
		text := string(s.edit_buf[:])
		if len(text) == 0 {
			return true
		}

		if mode == .Search {
			delete(s.search_query)
			s.search_query = strings.clone(text)
			jump_to_match(s, 1, include_current = true)
			return true
		}

		list := get_pane_list(s, s.active_pane)
		if mode == .Add_Item {
			append(list, strings.clone(text))
			s.cursor[s.active_pane] = len(list^) - 1
		}
		else if len(list^) > 0 {
			cur := clamp(s.cursor[s.active_pane], 0, len(list^) - 1)
			delete(list^[cur])
			list^[cur] = strings.clone(text)
		}
		recompute_synth(s)
	case 127, 8:
		// Backspace deletes the character immediately left of edit_cursor
		if s.edit_cursor > 0 && s.edit_cursor <= len(s.edit_buf) {
			ordered_remove(&s.edit_buf, s.edit_cursor - 1)
			s.edit_cursor -= 1
		}
	case:
		for b in key {
			if b >= 32 && b < 127 {
				inject_at(&s.edit_buf, s.edit_cursor, b)
				s.edit_cursor += 1
			}
		}
	}
	return true
}

@(private = "file")
jump_to_match :: proc(s: ^TUI_State, dir: int, include_current := false) {
	if s.search_query == "" {
		return
	}
	list := get_pane_list(s, s.active_pane)^
	if len(list) == 0 {
		return
	}
	ast, err := parse(s.search_query, s.ignore_case, context.temp_allocator)
	if err != .None {
		s.search_status = fmt.tprintf("Invalid regex: %v", err)
		return
	}
	prog := compile(ast, context.temp_allocator)
	total := len(list)
	cur := clamp(s.cursor[s.active_pane], 0, total - 1)
	start_offset := include_current ? 0 : 1
	for step := start_offset; step < total + start_offset; step += 1 {
		idx := (cur + dir * step) %% total
		if vm_match(prog, list[idx], anchored = false) {
			s.cursor[s.active_pane] = idx
			s.search_status = ""
			return
		}
	}
	s.search_status = "Pattern not found"
}

@(private = "file")
move_cursor :: proc(s: ^TUI_State, delta: int) {
	list := get_pane_list(s, s.active_pane)^
	if len(list) == 0 {
		s.cursor[s.active_pane] = 0
		return
	}
	s.cursor[s.active_pane] = clamp(s.cursor[s.active_pane] + delta, 0, len(list) - 1)
}

@(private = "file")
write_edit_prompt :: proc(b: ^strings.Builder, prefix, text: string, cursor: int, hint: string) {
	c := clamp(cursor, 0, len(text))
	before := text[:c]
	cursor_ch := c < len(text) ? text[c:c + 1] : " "
	after := c < len(text) ? text[c + 1:] : ""
	fmt.sbprintf(
		b,
		"\x1b[7m%s%s\x1b[0;4;1m%s\x1b[0;7m%s\x1b[0m%s",
		prefix,
		before,
		cursor_ch,
		after,
		hint,
	)
}
