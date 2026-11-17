package grepback

import "core:fmt"

Op :: enum u8 {
	Char,      // match literal byte `arg1`
	Bitmap,    // match against `program.bitmaps[arg1]`
	Split,     // push `arg2` onto backtrack stack, jump to `arg1`
	Jmp,       // unconditional jump to `arg1`
	Save,      // record current string pos into `saves[arg1]`
	Anchor,    // check Anchor_Kind(arg1)
	Lookaround,// evaluate sub-program at `arg1`; jump to `arg2` on success
	Match,     // accept match
}

Inst :: struct {
	op:       Op,
	arg1:     u32,
	arg2:     u32,
	// Extra metadata for Lookaround instructions
	positive: bool,
	behind:   bool,
	width:    u32,
}

Program :: struct {
	code:       []Inst,
	bitmaps:    []Bitmap,
	num_groups: int,
}

@(private = "file")
Compiler :: struct {
	code:      [dynamic]Inst,
	bitmaps:   [dynamic]Bitmap,
	max_group: int,
}

compile :: proc(root: ^Node, allocator := context.allocator) -> Program {
	c := Compiler {
		code    = make([dynamic]Inst, allocator),
		bitmaps = make([dynamic]Bitmap, allocator),
	}
	// Group 0 always records the overall match start/end span
	emit(&c, .Save, 0)
	compile_node(&c, root)
	emit(&c, .Save, 1)
	emit(&c, .Match)
	return Program {
		code       = c.code[:],
		bitmaps    = c.bitmaps[:],
		num_groups = c.max_group,
	}
}

destroy_program :: proc(prog: Program, allocator := context.allocator) {
	delete(prog.code, allocator)
	delete(prog.bitmaps, allocator)
}

@(private = "file")
compile_node :: proc(c: ^Compiler, node: ^Node) {
	if node == nil {
		return
	}

	switch v in node {
	case u8:
		emit(c, .Char, u32(v))

	case Bitmap:
		idx := add_bitmap(c, v)
		emit(c, .Bitmap, idx)

	case []^Node:
		for child in v {
			compile_node(c, child)
		}

	case Alt_Node:
		compile_alt(c, v.branches)

	case Repeat_Node:
		compile_repeat(c, v)

	case Group_Node:
		if v.index > 0 {
			if v.index > c.max_group {
				c.max_group = v.index
			}
			emit(c, .Save, u32(v.index * 2))
			compile_node(c, v.child)
			emit(c, .Save, u32(v.index * 2 + 1))
		} else {
			compile_node(c, v.child)
		}

	case Anchor_Kind:
		emit(c, .Anchor, u32(v))

	case Lookaround_Node:
		la_pc := emit(
			c,
			.Lookaround,
			0,
			0,
			positive = v.positive,
			behind = v.behind,
			width = u32(v.fixed_width),
		)
		jmp_pc := emit(c, .Jmp, 0)

		// Inline sub-program terminated by its own .Match
		c.code[la_pc].arg1 = current_pc(c)
		compile_node(c, v.child)
		emit(c, .Match)

		after := current_pc(c)
		c.code[la_pc].arg2 = after
		c.code[jmp_pc].arg1 = after
	}
}

@(private = "file")
compile_alt :: proc(c: ^Compiler, branches: []^Node) {
	if len(branches) == 0 {
		return
	}
	if len(branches) == 1 {
		compile_node(c, branches[0])
		return
	}

	// Chain Splits for N branches: Split(branch_i, next_split), branch_i, Jmp(end)
	end_jmps := make([dynamic]u32, context.temp_allocator)
	for branch, i in branches {
		is_last := i == len(branches) - 1
		if !is_last {
			split_pc := emit(c, .Split, 0, 0)
			c.code[split_pc].arg1 = current_pc(c)
			compile_node(c, branch)
			jmp_pc := emit(c, .Jmp, 0)
			append(&end_jmps, jmp_pc)
			c.code[split_pc].arg2 = current_pc(c)
		} else {
			compile_node(c, branch)
		}
	}

	end_pc := current_pc(c)
	for jmp_pc in end_jmps {
		c.code[jmp_pc].arg1 = end_pc
	}
}

@(private = "file")
compile_repeat :: proc(c: ^Compiler, r: Repeat_Node) {
	// Emit `min` mandatory copies
	for _ in 0 ..< r.min {
		compile_node(c, r.child)
	}

	// Unbounded tail: {m,} -> emit zero-or-more (*) loop
	if r.max == -1 {
		loop_pc := current_pc(c)
		split_pc := emit(c, .Split, 0, 0)
		body_pc := current_pc(c)

		compile_node(c, r.child)
		emit(c, .Jmp, loop_pc)
		after_pc := current_pc(c)

		if r.greedy {
			c.code[split_pc].arg1 = body_pc
			c.code[split_pc].arg2 = after_pc
		} else {
			c.code[split_pc].arg1 = after_pc
			c.code[split_pc].arg2 = body_pc
		}
		return
	}

	// Bounded tail: {m,n} -> emit (n - m) optional (?) blocks
	optional_count := r.max - r.min
	for _ in 0 ..< optional_count {
		split_pc := emit(c, .Split, 0, 0)
		body_pc := current_pc(c)
		compile_node(c, r.child)
		after_pc := current_pc(c)

		if r.greedy {
			c.code[split_pc].arg1 = body_pc
			c.code[split_pc].arg2 = after_pc
		} else {
			c.code[split_pc].arg1 = after_pc
			c.code[split_pc].arg2 = body_pc
		}
	}
}

@(private = "file")
current_pc :: proc(c: ^Compiler) -> u32 {
	return u32(len(c.code))
}

@(private = "file")
emit :: proc(
	c: ^Compiler,
	op: Op,
	arg1: u32 = 0,
	arg2: u32 = 0,
	positive := false,
	behind := false,
	width: u32 = 0,
) -> u32 {
	pc := current_pc(c)
	append(
		&c.code,
		Inst{op = op, arg1 = arg1, arg2 = arg2, positive = positive, behind = behind, width = width},
	)
	return pc
}

@(private = "file")
add_bitmap :: proc(c: ^Compiler, bm: Bitmap) -> u32 {
	for existing, i in c.bitmaps {
		if existing == bm {
			return u32(i)
		}
	}
	idx := u32(len(c.bitmaps))
	append(&c.bitmaps, bm)
	return idx
}

disassemble :: proc(prog: Program) {
	for inst, pc in prog.code {
		switch inst.op {
		case .Char:
			fmt.printf("%03d: CHAR   '%c' (0x%02x)\n", pc, inst.arg1, inst.arg1)
		case .Bitmap:
			fmt.printf("%03d: BITMAP #%d\n", pc, inst.arg1)
		case .Split:
			fmt.printf("%03d: SPLIT  %03d, %03d\n", pc, inst.arg1, inst.arg2)
		case .Jmp:
			fmt.printf("%03d: JMP    %03d\n", pc, inst.arg1)
		case .Save:
			fmt.printf("%03d: SAVE   %d\n", pc, inst.arg1)
		case .Anchor:
			fmt.printf("%03d: ANCHOR %v\n", pc, Anchor_Kind(inst.arg1))
		case .Lookaround:
			fmt.printf(
				"%03d: LOOK   target=%03d skip=%03d pos=%v behind=%v width=%d\n",
				pc,
				inst.arg1,
				inst.arg2,
				inst.positive,
				inst.behind,
				inst.width,
			)
		case .Match:
			fmt.printf("%03d: MATCH\n", pc)
		}
	}
}
