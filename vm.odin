package regenx

MAX_GROUPS :: 16

Thread :: struct {
	pc:    u32,
	sp:    int,
	saves: [MAX_GROUPS * 2]int,
}

// Matches `prog` against `input`.
// If `captures` is provided (len >= (prog.num_groups + 1) * 2), fills [start, end] byte offsets.
vm_match :: proc(
	prog: Program,
	input: string,
	anchored := false,
	captures: []int = nil,
	search_from := 0,
) -> bool {
	if len(prog.code) == 0 || search_from > len(input) {
		return false
	}
	must_start_at_zero := anchored
	if len(prog.code) >= 2 &&
	   prog.code[1].op == .Anchor &&
	   Anchor_Kind(prog.code[1].arg1) == .Start {
		must_start_at_zero = true
	}
	if must_start_at_zero && search_from > 0 {
		return false
	}
	max_start := must_start_at_zero ? search_from : len(input)
	for start_sp := search_from; start_sp <= max_start; start_sp += 1 {
		init_saves: [MAX_GROUPS * 2]int
		for &s in init_saves {
			s = -1
		}
		if matched, final_saves := vm_exec(prog, input, 0, start_sp, init_saves); matched {
			if captures != nil {
				n := min(len(captures), len(final_saves))
				copy(captures[:n], final_saves[:n])
			}
			return true
		}
	}
	return false
}

@(private = "file")
vm_exec :: proc(
	prog: Program,
	input: string,
	start_pc: u32,
	start_sp: int,
	init_saves: [MAX_GROUPS * 2]int,
) -> (
	bool,
	[MAX_GROUPS * 2]int,
) {
	stack := make([dynamic]Thread, context.temp_allocator)
	// Zero-width loop guard: records the last `sp` seen at each `Split` PC
	last_split_sp := make([]int, len(prog.code), context.temp_allocator)
	for &v in last_split_sp {
		v = -1
	}
	pc := start_pc
	sp := start_sp
	saves := init_saves
	for {
		inst := prog.code[pc]
		switch inst.op {
		case .Char:
			if sp < len(input) && input[sp] == u8(inst.arg1) {
				sp += 1
				pc += 1
				continue
			}
		case .Bitmap:
			if sp < len(input) && bitmap_has(prog.bitmaps[inst.arg1], input[sp]) {
				sp += 1
				pc += 1
				continue
			}
		case .Split:
			// Guard against infinite zero-width loops like (a*)*
			if last_split_sp[pc] == sp {
				// Fall through to backtrack
			} else {
				last_split_sp[pc] = sp
				append(&stack, Thread{pc = inst.arg2, sp = sp, saves = saves})
				pc = inst.arg1
				continue
			}
		case .Jmp:
			pc = inst.arg1
			continue
		case .Save:
			if int(inst.arg1) < len(saves) {
				saves[inst.arg1] = sp
			}
			pc += 1
			continue
		case .Anchor:
			if check_anchor(Anchor_Kind(inst.arg1), input, sp) {
				pc += 1
				continue
			}
		case .Lookaround:
			sub_ok := false
			if inst.behind {
				if sp >= int(inst.width) {
					sub_ok, _ = vm_exec(prog, input, inst.arg1, sp - int(inst.width), saves)
				}
			} else {
				sub_ok, _ = vm_exec(prog, input, inst.arg1, sp, saves)
			}
			if sub_ok == inst.positive {
				pc = inst.arg2
				continue
			}
		case .Match:
			return true, saves
		}
		// Current branch failed -> pop next backtrack state
		if len(stack) == 0 {
			return false, saves
		}
		top := pop(&stack)
		pc = top.pc
		sp = top.sp
		saves = top.saves
	}
}

@(private = "file")
check_anchor :: proc(kind: Anchor_Kind, input: string, sp: int) -> bool {
	switch kind {
	case .Start:
		return sp == 0
	case .End:
		return sp == len(input)
	case .Word_Boundary:
		prev_word := sp > 0 && bitmap_has(BITMAP_WORD, input[sp - 1])
		curr_word := sp < len(input) && bitmap_has(BITMAP_WORD, input[sp])
		return prev_word != curr_word
	}
	return false
}
