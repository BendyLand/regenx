package grepback

import "core:fmt"
import "core:strings"

ast_to_string :: proc(root: ^Node, allocator := context.allocator) -> string {
	if root == nil {
		return ""
	}
	b := strings.builder_make(allocator)
	write_node(&b, root)
	return strings.to_string(b)
}

@(private = "file")
write_node :: proc(b: ^strings.Builder, node: ^Node) {
	if node == nil {
		return
	}
	switch v in node {
	case u8:
		write_escaped_literal(b, v)
	case Bitmap:
		write_bitmap(b, v)
	case []^Node:
		for child in v {
			// Wrap Alternations inside a Concat so a(b|c) doesn't print as ab|c
			if _, is_alt := child.(Alt_Node); is_alt {
				strings.write_string(b, "(?:")
				write_node(b, child)
				strings.write_byte(b, ')')
			} else {
				write_node(b, child)
			}
		}
	case Alt_Node:
		for branch, i in v.branches {
			if i > 0 {
				strings.write_byte(b, '|')
			}
			write_node(b, branch)
		}
	case Repeat_Node:
		needs_parens := false
		switch c in v.child {
		case Alt_Node, Repeat_Node:
			needs_parens = true
		case []^Node:
			needs_parens = len(c) > 1
		case u8, Bitmap, Group_Node, Anchor_Kind, Lookaround_Node:
			needs_parens = false
		}
		if needs_parens {
			strings.write_string(b, "(?:")
			write_node(b, v.child)
			strings.write_byte(b, ')')
		} else {
			write_node(b, v.child)
		}
		// Quantifier suffix
		if v.min == 0 && v.max == 1 {
			strings.write_byte(b, '?')
		} else if v.min == 0 && v.max == -1 {
			strings.write_byte(b, '*')
		} else if v.min == 1 && v.max == -1 {
			strings.write_byte(b, '+')
		} else if v.max == -1 {
			fmt.sbprintf(b, "{{%d,}}", v.min)
		} else if v.min == v.max {
			fmt.sbprintf(b, "{{%d}}", v.min)
		} else {
			fmt.sbprintf(b, "{{%d,%d}}", v.min, v.max)
		}
		if !v.greedy {
			strings.write_byte(b, '?')
		}
	case Group_Node:
		if v.index == 0 {
			strings.write_string(b, "(?:")
		} else {
			strings.write_byte(b, '(')
		}
		write_node(b, v.child)
		strings.write_byte(b, ')')
	case Anchor_Kind:
		switch v {
		case .Start:
			strings.write_byte(b, '^')
		case .End:
			strings.write_byte(b, '$')
		case .Word_Boundary:
			strings.write_string(b, `\b`)
		}
	case Lookaround_Node:
		if v.behind {
			strings.write_string(b, v.positive ? "(?<=" : "(?<!")
		} else {
			strings.write_string(b, v.positive ? "(?=" : "(?!")
		}
		write_node(b, v.child)
		strings.write_byte(b, ')')
	}
}

@(private = "file")
write_bitmap :: proc(b: ^strings.Builder, bm: Bitmap) {
	// Common shorthand classes
	if bm == BITMAP_ANY {
		strings.write_byte(b, '.')
		return
	}
	if bm == BITMAP_DIGIT {
		strings.write_string(b, `\d`)
		return
	}
	if bm == bitmap_invert(BITMAP_DIGIT) {
		strings.write_string(b, `\D`)
		return
	}
	if bm == BITMAP_WORD {
		strings.write_string(b, `\w`)
		return
	}
	if bm == bitmap_invert(BITMAP_WORD) {
		strings.write_string(b, `\W`)
		return
	}
	if bm == BITMAP_SPACE {
		strings.write_string(b, `\s`)
		return
	}
	if bm == bitmap_invert(BITMAP_SPACE) {
		strings.write_string(b, `\S`)
		return
	}
	// Single-character bitmap -> emit as plain literal
	count := bitmap_count(bm)
	if count == 1 {
		for c in 0 ..= 255 {
			if bitmap_has(bm, u8(c)) {
				write_escaped_literal(b, u8(c))
				return
			}
		}
	}
	// Bracket expression (negate if more than half of ASCII is set)
	strings.write_byte(b, '[')
	target := bm
	if count > 128 {
		strings.write_byte(b, '^')
		target = bitmap_invert(bm)
	}
	i := 0
	for i <= 255 {
		if !bitmap_has(target, u8(i)) {
			i += 1
			continue
		}
		j := i
		for j + 1 <= 255 && bitmap_has(target, u8(j + 1)) {
			j += 1
		}
		// Collapse runs of 3+ consecutive bytes into a-z ranges
		if j - i >= 2 {
			write_escaped_class_byte(b, u8(i))
			strings.write_byte(b, '-')
			write_escaped_class_byte(b, u8(j))
		} else {
			for k in i ..= j {
				write_escaped_class_byte(b, u8(k))
			}
		}
		i = j + 1
	}
	strings.write_byte(b, ']')
}

@(private = "file")
write_escaped_literal :: proc(b: ^strings.Builder, c: u8) {
	switch c {
	case '\\', '.', '+', '*', '?', '(', ')', '[', ']', '{', '}', '^', '$', '|':
		strings.write_byte(b, '\\')
		strings.write_byte(b, c)
	case '\n':
		strings.write_string(b, `\n`)
	case '\r':
		strings.write_string(b, `\r`)
	case '\t':
		strings.write_string(b, `\t`)
	case:
		if c < 0x20 || c >= 0x7f {
			fmt.sbprintf(b, `\x%02x`, c)
		} else {
			strings.write_byte(b, c)
		}
	}
}

@(private = "file")
write_escaped_class_byte :: proc(b: ^strings.Builder, c: u8) {
	switch c {
	case '\\', ']', '^', '-':
		strings.write_byte(b, '\\')
		strings.write_byte(b, c)
	case '\n':
		strings.write_string(b, `\n`)
	case '\r':
		strings.write_string(b, `\r`)
	case '\t':
		strings.write_string(b, `\t`)
	case:
		if c < 0x20 || c >= 0x7f {
			fmt.sbprintf(b, `\x%02x`, c)
		} else {
			strings.write_byte(b, c)
		}
	}
}
