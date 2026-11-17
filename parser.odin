package grepback

import "base:runtime"
import "core:strings"

Parse_Error :: enum {
	None,
	Unexpected_EOF,
	Unmatched_Paren,
	Unclosed_Class,
	Invalid_Range,
	Invalid_Quantifier,
	Invalid_Escape,
	Variable_Length_Lookbehind,
	Nothing_To_Repeat,
}

Parser :: struct {
	src:         string,
	pos:         int,
	group_count: int,
	allocator:   runtime.Allocator,
}

parse :: proc(pattern: string, allocator := context.allocator) -> (res: ^Node, err: Parse_Error) {
	p := Parser {
		src       = pattern,
		allocator = allocator,
	}
	root := parse_alt(&p) or_return
	if p.pos < len(p.src) {
		return nil, .Unmatched_Paren
	}
	return root, .None
}

@(private = "file")
peek :: proc(p: ^Parser) -> (u8, bool) {
	if p.pos >= len(p.src) {
		return 0, false
	}
	return p.src[p.pos], true
}

@(private = "file")
advance :: proc(p: ^Parser) -> (u8, bool) {
	if p.pos >= len(p.src) {
		return 0, false
	}
	b := p.src[p.pos]
	p.pos += 1
	return b, true
}

@(private = "file")
match_byte :: proc(p: ^Parser, expected: u8) -> bool {
	if b, ok := peek(p); ok && b == expected {
		p.pos += 1
		return true
	}
	return false
}

@(private = "file")
match_str :: proc(p: ^Parser, prefix: string) -> bool {
	if strings.has_prefix(p.src[p.pos:], prefix) {
		p.pos += len(prefix)
		return true
	}
	return false
}

@(private = "file")
parse_alt :: proc(p: ^Parser) -> (res: ^Node, err: Parse_Error) {
	first := parse_concat(p) or_return
	if !match_byte(p, '|') {
		return first, .None
	}
	branches := make([dynamic]^Node, p.allocator)
	append(&branches, first)
	for {
		branch := parse_concat(p) or_return
		append(&branches, branch)
		if !match_byte(p, '|') {
			break
		}
	}
	return new_node(Alt_Node{branches = branches[:]}, p.allocator), .None
}

@(private = "file")
parse_concat :: proc(p: ^Parser) -> (res: ^Node, err: Parse_Error) {
	items := make([dynamic]^Node, p.allocator)
	for {
		b, ok := peek(p)
		if !ok || b == '|' || b == ')' {
			break
		}
		item := parse_repeat(p) or_return
		append(&items, item)
	}
	if len(items) == 0 {
		delete(items)
		return new_node([]^Node{}, p.allocator), .None
	}
	if len(items) == 1 {
		single := items[0]
		delete(items)
		return single, .None
	}
	return new_node(items[:], p.allocator), .None
}

@(private = "file")
parse_repeat :: proc(p: ^Parser) -> (res: ^Node, err: Parse_Error) {
	atom := parse_atom(p) or_return
	b, ok := peek(p)
	if !ok {
		return atom, .None
	}
	min, max: int
	has_quant := true
	switch b {
	case '*':
		p.pos += 1
		min, max = 0, -1
	case '+':
		p.pos += 1
		min, max = 1, -1
	case '?':
		p.pos += 1
		min, max = 0, 1
	case '{':
		min, max = parse_braced_quantifier(p) or_return
	case:
		has_quant = false
	}
	if !has_quant {
		return atom, .None
	}
	// Disallow repeating zero-width assertions
	switch _ in atom {
	case Anchor_Kind, Lookaround_Node:
		return nil, .Nothing_To_Repeat
	case u8, Bitmap, []^Node, Alt_Node, Repeat_Node, Group_Node:
	}
	greedy := !match_byte(p, '?')
	return new_node(Repeat_Node{child = atom, min = min, max = max, greedy = greedy}, p.allocator),
		.None
}

@(private = "file")
parse_braced_quantifier :: proc(p: ^Parser) -> (min, max: int, err: Parse_Error) {
	p.pos += 1 // consume '{'
	min = parse_uint(p) or_return
	if match_byte(p, '}') {
		return min, min, .None
	}
	if !match_byte(p, ',') {
		return 0, 0, .Invalid_Quantifier
	}
	if match_byte(p, '}') {
		return min, -1, .None // {m,}
	}
	max = parse_uint(p) or_return
	if !match_byte(p, '}') || max < min {
		return 0, 0, .Invalid_Quantifier
	}
	return min, max, .None
}

@(private = "file")
parse_uint :: proc(p: ^Parser) -> (val: int, err: Parse_Error) {
	start := p.pos
	for {
		b, ok := peek(p)
		if !ok || b < '0' || b > '9' {
			break
		}
		val = val * 10 + int(b - '0')
		p.pos += 1
	}
	if p.pos == start {
		return 0, .Invalid_Quantifier
	}
	return val, .None
}

@(private = "file")
parse_atom :: proc(p: ^Parser) -> (^Node, Parse_Error) {
	b, ok := advance(p)
	if !ok {
		return nil, .Unexpected_EOF
	}
	switch b {
	case '^':
		return new_node(Anchor_Kind.Start, p.allocator), .None
	case '$':
		return new_node(Anchor_Kind.End, p.allocator), .None
	case '.':
		return new_node(BITMAP_ANY, p.allocator), .None
	case '[':
		return parse_class(p)
	case '(':
		return parse_group(p)
	case '\\':
		return parse_escape(p)
	case '*', '+', '?', '{':
		return nil, .Nothing_To_Repeat
	case:
		return new_node(b, p.allocator), .None
	}
}

@(private = "file")
parse_group :: proc(p: ^Parser) -> (res: ^Node, err: Parse_Error) {
	is_lookaround := false
	positive := false
	behind := false
	group_idx := 0
	if match_str(p, "?:") {
		group_idx = 0
	}
	else if match_str(p, "?=") {
		is_lookaround, positive, behind = true, true, false
	}
	else if match_str(p, "?!") {
		is_lookaround, positive, behind = true, false, false
	}
	else if match_str(p, "?<=") {
		is_lookaround, positive, behind = true, true, true
	}
	else if match_str(p, "?<!") {
		is_lookaround, positive, behind = true, false, true
	}
	else {
		p.group_count += 1
		group_idx = p.group_count
	}
	child := parse_alt(p) or_return
	if !match_byte(p, ')') {
		return nil, .Unmatched_Paren
	}
	if is_lookaround {
		width := 0
		if behind {
			ok: bool
			width, ok = calc_fixed_width(child)
			if !ok {
				return nil, .Variable_Length_Lookbehind
			}
		}
		return new_node(
				Lookaround_Node {
					child = child,
					positive = positive,
					behind = behind,
					fixed_width = width,
				},
				p.allocator,
			),
			.None
	}
	return new_node(Group_Node{child = child, index = group_idx}, p.allocator), .None
}

@(private = "file")
parse_escape :: proc(p: ^Parser) -> (res: ^Node, err: Parse_Error) {
	b, ok := advance(p)
	if !ok {
		return nil, .Invalid_Escape
	}
	switch b {
	case 'd':
		return new_node(BITMAP_DIGIT, p.allocator), .None
	case 'D':
		return new_node(bitmap_invert(BITMAP_DIGIT), p.allocator), .None
	case 'w':
		return new_node(BITMAP_WORD, p.allocator), .None
	case 'W':
		return new_node(bitmap_invert(BITMAP_WORD), p.allocator), .None
	case 's':
		return new_node(BITMAP_SPACE, p.allocator), .None
	case 'S':
		return new_node(bitmap_invert(BITMAP_SPACE), p.allocator), .None
	case 'b':
		return new_node(Anchor_Kind.Word_Boundary, p.allocator), .None
	case:
		lit := parse_escaped_byte(p, b) or_return
		return new_node(lit, p.allocator), .None
	}
}

@(private = "file")
parse_escaped_byte :: proc(p: ^Parser, esc: u8) -> (res: u8, err: Parse_Error) {
	switch esc {
	case 'n':
		return '\n', .None
	case 'r':
		return '\r', .None
	case 't':
		return '\t', .None
	case 'v':
		return '\v', .None
	case 'f':
		return '\f', .None
	case 'x':
		hi := parse_hex_digit(p) or_return
		lo := parse_hex_digit(p) or_return
		return (hi << 4) | lo, .None
	case:
		return esc, .None
	}
}

@(private = "file")
parse_hex_digit :: proc(p: ^Parser) -> (u8, Parse_Error) {
	b, ok := advance(p)
	if !ok {
		return 0, .Invalid_Escape
	}
	switch b {
	case '0' ..= '9':
		return b - '0', .None
	case 'a' ..= 'f':
		return b - 'a' + 10, .None
	case 'A' ..= 'F':
		return b - 'A' + 10, .None
	case:
		return 0, .Invalid_Escape
	}
}

@(private = "file")
parse_class :: proc(p: ^Parser) -> (res: ^Node, err: Parse_Error) {
	negated := match_byte(p, '^')
	bm: Bitmap
	// Allow literal ']' as the very first character in a class: []a] or [^]a]
	if match_byte(p, ']') {
		bitmap_set(&bm, ']')
	}
	for {
		b, ok := advance(p)
		if !ok {
			return nil, .Unclosed_Class
		}
		if b == ']' {
			break
		}
		// Handle shorthand classes inside [...] like [\d\s]
		if b == '\\' {
			esc, esc_ok := advance(p)
			if !esc_ok {
				return nil, .Invalid_Escape
			}
			switch esc {
			case 'd':
				bm = bitmap_union(bm, BITMAP_DIGIT)
				continue
			case 'D':
				bm = bitmap_union(bm, bitmap_invert(BITMAP_DIGIT))
				continue
			case 'w':
				bm = bitmap_union(bm, BITMAP_WORD)
				continue
			case 'W':
				bm = bitmap_union(bm, bitmap_invert(BITMAP_WORD))
				continue
			case 's':
				bm = bitmap_union(bm, BITMAP_SPACE)
				continue
			case 'S':
				bm = bitmap_union(bm, bitmap_invert(BITMAP_SPACE))
				continue
			case:
				b = parse_escaped_byte(p, esc) or_return
			}
		}
		// Check for a-z range (only if '-' is not immediately followed by ']')
		if next, has_next := peek(p); has_next && next == '-' {
			if p.pos + 1 < len(p.src) && p.src[p.pos + 1] != ']' {
				p.pos += 1 // consume '-'
				hi, hi_ok := advance(p)
				if !hi_ok {
					return nil, .Unclosed_Class
				}
				if hi == '\\' {
					esc, esc_ok := advance(p)
					if !esc_ok {
						return nil, .Invalid_Escape
					}
					hi = parse_escaped_byte(p, esc) or_return
				}
				if b > hi {
					return nil, .Invalid_Range
				}
				bitmap_set_range(&bm, b, hi)
				continue
			}
		}
		bitmap_set(&bm, b)
	}
	if negated {
		bm = bitmap_invert(bm)
	}
	return new_node(bm, p.allocator), .None
}

calc_fixed_width :: proc(node: ^Node) -> (width: int, ok: bool) {
	switch v in node {
	case u8, Bitmap:
		return 1, true
	case Anchor_Kind, Lookaround_Node:
		return 0, true
	case []^Node:
		total := 0
		for child in v {
			w := calc_fixed_width(child) or_return
			total += w
		}
		return total, true
	case Alt_Node:
		if len(v.branches) == 0 {
			return 0, true
		}
		expected := calc_fixed_width(v.branches[0]) or_return
		for branch in v.branches[1:] {
			w := calc_fixed_width(branch) or_return
			if w != expected {
				return 0, false
			}
		}
		return expected, true
	case Repeat_Node:
		if v.max == -1 || v.min != v.max {
			return 0, false
		}
		w := calc_fixed_width(v.child) or_return
		return v.min * w, true
	case Group_Node:
		return calc_fixed_width(v.child)
	}
	return 0, false
}
