package grepback

Anchor_Kind :: enum {
	Start,
	End,
	Word_Boundary,
}

Repeat_Node :: struct {
	child:  ^Node,
	min:    int,
	max:    int, // -1 = unbounded (* or +)
	greedy: bool,
}

Group_Node :: struct {
	child: ^Node,
	index: int, // 0 = non-capturing (?:...)
}

Lookaround_Node :: struct {
	child:       ^Node,
	positive:    bool,
	behind:      bool,
	fixed_width: int,
}

Node :: union {
	u8,         // Literal byte
	Bitmap,     // Character class [...]
	[]^Node,    // Concat (use a distinct wrapper struct for Alt)
	Alt_Node,
	Repeat_Node,
	Group_Node,
	Anchor_Kind,
	Lookaround_Node,
}

Alt_Node :: struct {
	branches: []^Node,
}

// Allocates any Node variant in the active allocator (defaults to context.allocator,
// pass context.temp_allocator during synthesis).
new_node :: proc(val: Node, allocator := context.allocator) -> ^Node {
	n := new(Node, allocator)
	n^ = val
	return n
}
