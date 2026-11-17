package grepback

import "core:math/bits"
import "core:slice"
import "core:strings"

Synth_Result :: struct {
	pattern:   string,
	pos_hits:  int,
	neg_hits:  int,
	mdl_score: int,
	valid:     bool,
}

Candidate :: struct {
	ast:       ^Node,
	pattern:   string,
	pos_hits:  int,
	neg_hits:  int,
	mdl_score: int,
	valid:     bool,
}

// Synthesizes up to `top_k` candidate regexes matching `pos` and rejecting `neg`.
// Returned pattern strings are allocated with `allocator`; all scratch work uses `temp_allocator`.
synthesize :: proc(
	pos: []string,
	neg: []string,
	ignore_case := false,
	anchored := true,
	top_k := 5,
	allocator := context.allocator,
) -> []Synth_Result {
	if len(pos) == 0 {
		return nil
	}

	scratch := context.temp_allocator
	candidates := make([dynamic]Candidate, scratch)

	// 1. Seed A: Needleman-Wunsch consensus alignment across positive examples
	if nw_ast := seed_needleman_wunsch(pos, ignore_case, anchored, scratch); nw_ast != nil {
		append(&candidates, evaluate_candidate(nw_ast, pos, neg, anchored, scratch))
	}

	// 2. Seed B: Exact literal alternation fallback
	if alt_ast := seed_literal_alt(pos, ignore_case, anchored, scratch); alt_ast != nil {
		append(&candidates, evaluate_candidate(alt_ast, pos, neg, anchored, scratch))
	}

	beam_search(
		&candidates,
		pos,
		neg,
		ignore_case,
		anchored,
		beam_width = 16,
		max_steps = 20,
		alloc = scratch,
	)

	rank_candidates(candidates[:])

	n := min(top_k, len(candidates))
	results := make([]Synth_Result, n, allocator)
	for i in 0 ..< n {
		c := candidates[i]
		results[i] = Synth_Result {
			pattern   = strings.clone(c.pattern, allocator),
			pos_hits  = c.pos_hits,
			neg_hits  = c.neg_hits,
			mdl_score = c.mdl_score,
			valid     = c.valid,
		}
	}
	return results
}

evaluate_candidate :: proc(
	ast: ^Node,
	pos: []string,
	neg: []string,
	anchored: bool,
	alloc := context.temp_allocator,
) -> Candidate {
	pat := ast_to_string(ast, alloc)
	prog := compile(ast, alloc)

	pos_hits := 0
	for s in pos {
		if vm_match(prog, s, anchored = anchored) {
			pos_hits += 1
		}
	}

	neg_hits := 0
	for s in neg {
		if vm_match(prog, s, anchored = anchored) {
			neg_hits += 1
		}
	}

	return Candidate {
		ast = ast,
		pattern = pat,
		pos_hits = pos_hits,
		neg_hits = neg_hits,
		mdl_score = mdl_cost(ast),
		valid = (pos_hits == len(pos)) && (neg_hits == 0),
	}
}

// --- Oracle & MDL Scorer ---

mdl_cost :: proc(node: ^Node) -> int {
	if node == nil {
		return 0
	}
	switch n in node {
	case u8:
		return 1 // Preserve concrete shared prefixes (foo_, item_)
	case Anchor_Kind:
		return 1
	case Bitmap:
		pop := bitmap_popcount(n)
		if pop >= 255 {
			return 14 // Heavy penalty for '.'
		}
		if n == BITMAP_WORD {
			return 8 // Prefer tighter \d or [a-z] over \w
		}
		if n == BITMAP_DIGIT || n == BITMAP_SPACE || is_alpha_class(n) {
			return 4 // Standard classes beat ad-hoc bitmaps like [29] or [rt]
		}
		return 5 + pop / 8 // Ad-hoc character sets like [29] or [rt]
	case []^Node:
		total := 0
		for child in n {
			total += mdl_cost(child)
		}
		return total
	case Alt_Node:
		total := 3 * len(n.branches)
		for branch in n.branches {
			total += mdl_cost(branch)
		}
		return total
	case Repeat_Node:
		penalty := 1
		if n.max == -1 {
			penalty = (n.min == 0) ? 5 : 3 // Prefer '+' over '*'
		}
		return penalty + mdl_cost(n.child)
	case Group_Node:
		return 1 + mdl_cost(n.child)
	case Lookaround_Node:
		return 4 + mdl_cost(n.child)
	}
	return 2
}

rank_candidates :: proc(cands: []Candidate) {
	slice.sort_by(cands, proc(a, b: Candidate) -> bool {
		if a.valid != b.valid {
			return a.valid
		}
		score_a := a.pos_hits * 10 - a.neg_hits * 25
		score_b := b.pos_hits * 10 - b.neg_hits * 25
		if score_a != score_b {
			return score_a > score_b
		}
		return a.mdl_score < b.mdl_score
	})
}

// --- Needleman-Wunsch Sequence Alignment Seed ---

@(private = "file")
seed_needleman_wunsch :: proc(
	pos: []string,
	ignore_case: bool,
	anchored: bool,
	alloc := context.temp_allocator,
) -> ^Node {
	seq := string_to_atoms(pos[0], ignore_case, alloc)
	for i := 1; i < len(pos); i += 1 {
		next_seq := string_to_atoms(pos[i], ignore_case, alloc)
		seq = nw_align_and_merge(seq, next_seq, alloc)
	}

	if !anchored {
		return new_node(seq, alloc)
	}

	full := make([dynamic]^Node, 0, len(seq) + 2, alloc)
	append(&full, new_node(Anchor_Kind.Start, alloc))
	append(&full, ..seq)
	append(&full, new_node(Anchor_Kind.End, alloc))
	return new_node(full[:], alloc)
}

@(private = "file")
seed_literal_alt :: proc(
	pos: []string,
	ignore_case: bool,
	anchored: bool,
	alloc := context.temp_allocator,
) -> ^Node {
	branches := make([]^Node, len(pos), alloc)
	for s, idx in pos {
		atoms := string_to_atoms(s, ignore_case, alloc)
		branches[idx] = new_node(atoms, alloc)
	}
	grp := new_node(
		Group_Node{child = new_node(Alt_Node{branches = branches}, alloc), index = 0},
		alloc,
	)
	if !anchored {
		return grp
	}

	parts := make([]^Node, 3, alloc)
	parts[0] = new_node(Anchor_Kind.Start, alloc)
	parts[1] = grp
	parts[2] = new_node(Anchor_Kind.End, alloc)
	return new_node(parts, alloc)
}

@(private = "file")
nw_align_and_merge :: proc(a, b: []^Node, alloc := context.temp_allocator) -> []^Node {
	rows := len(a) + 1
	cols := len(b) + 1
	dp := make([]int, rows * cols, alloc)

	GAP :: -2
	for i in 0 ..< rows do dp[i * cols] = i * GAP
	for j in 0 ..< cols do dp[j] = j * GAP

	for i := 1; i < rows; i += 1 {
		for j := 1; j < cols; j += 1 {
			sub := dp[(i - 1) * cols + (j - 1)] + atom_similarity(a[i - 1], b[j - 1])
			del := dp[(i - 1) * cols + j] + GAP
			ins := dp[i * cols + (j - 1)] + GAP
			dp[i * cols + j] = max(sub, max(del, ins))
		}
	}

	rev := make([dynamic]^Node, alloc)
	i, j := len(a), len(b)
	for i > 0 || j > 0 {
		if i > 0 &&
		   j > 0 &&
		   dp[i * cols + j] == dp[(i - 1) * cols + (j - 1)] + atom_similarity(a[i - 1], b[j - 1]) {
			append(&rev, merge_atoms(a[i - 1], b[j - 1], alloc))
			i -= 1
			j -= 1
		}
		else if i > 0 && dp[i * cols + j] == dp[(i - 1) * cols + j] + GAP {
			append(&rev, make_optional(a[i - 1], alloc))
			i -= 1
		}
		else {
			append(&rev, make_optional(b[j - 1], alloc))
			j -= 1
		}
	}

	slice.reverse(rev[:])
	return rev[:]
}

@(private = "file")
atom_similarity :: proc(x, y: ^Node) -> int {
	bx := node_to_bitmap(x)
	by := node_to_bitmap(y)
	if bx == by {
		return 3
	}
	if (bitmap_is_subset(bx, BITMAP_DIGIT) && bitmap_is_subset(by, BITMAP_DIGIT)) ||
	   (bitmap_is_subset(bx, BITMAP_WORD) && bitmap_is_subset(by, BITMAP_WORD)) ||
	   (bitmap_is_subset(bx, BITMAP_SPACE) && bitmap_is_subset(by, BITMAP_SPACE)) {
		return 1
	}
	return -2
}

@(private = "file")
merge_atoms :: proc(x, y: ^Node, alloc := context.temp_allocator) -> ^Node {
	bx := node_to_bitmap(x)
	by := node_to_bitmap(y)
	if bx == by {
		return x
	}
	return new_node(bitmap_union(bx, by), alloc)
}

@(private = "file")
make_optional :: proc(node: ^Node, alloc := context.temp_allocator) -> ^Node {
	if r, ok := node.(Repeat_Node); ok {
		r.min = 0
		return new_node(r, alloc)
	}
	return new_node(Repeat_Node{child = node, min = 0, max = 1, greedy = true}, alloc)
}

@(private = "file")
string_to_atoms :: proc(s: string, ignore_case: bool, alloc := context.temp_allocator) -> []^Node {
	atoms := make([]^Node, len(s), alloc)
	for i := 0; i < len(s); i += 1 {
		b := s[i]
		if ignore_case && ((b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')) {
			bm: Bitmap
			bitmap_set(&bm, b)
			bitmap_set(&bm, b ~ 0x20)
			atoms[i] = new_node(bm, alloc)
		}
		else {
			atoms[i] = new_node(b, alloc)
		}
	}
	return atoms
}

@(private = "file")
node_to_bitmap :: proc(node: ^Node) -> Bitmap {
	switch n in node {
	case u8:
		bm: Bitmap
		bitmap_set(&bm, n)
		return bm
	case Bitmap:
		return n
	case Repeat_Node:
		return node_to_bitmap(n.child)
	case Anchor_Kind, []^Node, Alt_Node, Group_Node, Lookaround_Node:
		return {}
	}
	return {}
}

@(private = "file")
bitmap_is_subset :: proc(sub, sup: Bitmap) -> bool {
	return(
		(sub[0] & ~sup[0]) == 0 &&
		(sub[1] & ~sup[1]) == 0 &&
		(sub[2] & ~sup[2]) == 0 &&
		(sub[3] & ~sup[3]) == 0 \
	)
}

@(private = "file")
bitmap_popcount :: proc(bm: Bitmap) -> int {
	return int(
		bits.count_ones(bm[0]) +
		bits.count_ones(bm[1]) +
		bits.count_ones(bm[2]) +
		bits.count_ones(bm[3]),
	)
}

@(private = "file")
beam_search :: proc(
	candidates: ^[dynamic]Candidate,
	pos: []string,
	neg: []string,
	ignore_case: bool,
	anchored: bool,
	beam_width: int,
	max_steps: int,
	alloc := context.temp_allocator,
) {
	seen := make(map[string]bool, 64, alloc)
	for c in candidates {
		seen[c.pattern] = true
	}

	frontier := make([dynamic]Candidate, alloc)
	append(&frontier, ..candidates[:])

	for step := 0; step < max_steps && len(frontier) > 0; step += 1 {
		next_gen := make([dynamic]Candidate, alloc)

		for cand in frontier {
			children := generate_neighbors(cand, pos, neg, ignore_case, anchored, alloc)
			for child_ast in children {
				eval := evaluate_candidate(child_ast, pos, neg, anchored, alloc)
				if eval.pattern in seen {
					continue
				}
				seen[eval.pattern] = true
				append(candidates, eval)
				append(&next_gen, eval)
			}
		}

		if len(next_gen) == 0 {
			break
		}

		rank_candidates(next_gen[:])
		clear(&frontier)
		keep := min(beam_width, len(next_gen))
		append(&frontier, ..next_gen[:keep])
	}
}

@(private = "file")
generate_neighbors :: proc(
	cand: Candidate,
	pos: []string,
	neg: []string,
	ignore_case: bool,
	anchored: bool,
	alloc := context.temp_allocator,
) -> [dynamic]^Node {
	out := make([dynamic]^Node, alloc)
	seq, is_concat := cand.ast.([]^Node)
	if !is_concat {
		return out
	}

	// Widen character bitmaps -> \d, [a-z], [A-Z], \w
	for node, idx in seq {
		bm := node_to_bitmap(node)
		if bitmap_popcount(bm) == 0 {
			continue
		}
		for target in standard_classes(bm, alloc) {
			if target == bm {
				continue
			}
			cloned := slice.clone(seq, alloc)
			cloned[idx] = replace_inner_bitmap(node, target, alloc)
			append(&out, new_node(cloned, alloc))
		}
	}

	// Collapse adjacent identical atoms into + or *
	for i := 0; i + 1 < len(seq); i += 1 {
		b1 := node_to_bitmap(seq[i])
		b2 := node_to_bitmap(seq[i + 1])
		if bitmap_popcount(b1) > 0 && b1 == b2 {
			min_rep := 2
			if r1, ok := seq[i].(Repeat_Node); ok && r1.min == 0 do min_rep = 0
			if r2, ok := seq[i + 1].(Repeat_Node); ok && r2.min == 0 do min_rep = 0
			if min_rep > 0 do min_rep = 1

			base := strip_repeat(seq[i])
			rep := new_node(
				Repeat_Node{child = base, min = min_rep, max = -1, greedy = true},
				alloc,
			)

			merged := make([dynamic]^Node, 0, len(seq) - 1, alloc)
			append(&merged, ..seq[:i])
			append(&merged, rep)
			append(&merged, ..seq[i + 2:])
			append(&out, new_node(merged[:], alloc))
		}
	}

	// Promote single atom to + (min=1, max=-1) when positive examples vary in length
	if cand.pos_hits == len(pos) && cand.neg_hits > 0 {
		prog := compile(cand.ast, alloc)
		for bad in neg {
			caps: [2]int
			if !vm_match(prog, bad, captures = caps[:], anchored = anchored) {
				continue
			}
			matched_tail := anchored ? bad : bad[caps[0]:]
			if la_ast := inject_negative_lookahead(
				seq,
				matched_tail,
				ignore_case,
				anchored,
				alloc,
			); la_ast != nil {
				append(&out, la_ast)
			}
		}
	}

	// Specialize with negative lookahead (?!suffix$) when neg examples still match
	if cand.pos_hits == len(pos) && cand.neg_hits > 0 {
		prog := compile(cand.ast, alloc)
		for bad in neg {
			if !vm_match(prog, bad, anchored = true) {
				continue
			}
			if la_ast := inject_negative_lookahead(seq, bad, ignore_case, anchored, alloc);
			   la_ast != nil {
				append(&out, la_ast)
			}
		}
	}

	return out
}

@(private = "file")
inject_negative_lookahead :: proc(
	seq: []^Node,
	bad: string,
	ignore_case: bool,
	anchored: bool,
	alloc := context.temp_allocator,
) -> ^Node {
	seq_idx := 0
	if len(seq) > 0 {
		if a, ok := seq[0].(Anchor_Kind); ok && a == .Start {
			seq_idx = 1
		}
	}

	str_idx := 0
	for seq_idx < len(seq) && str_idx < len(bad) {
		if lit, ok := seq[seq_idx].(u8); ok && lit == bad[str_idx] {
			seq_idx += 1
			str_idx += 1
		}
		else {
			break
		}
	}

	if str_idx >= len(bad) {
		return nil
	}

	rem_atoms := string_to_atoms(bad[str_idx:], ignore_case, alloc)
	la_seq := make([dynamic]^Node, 0, len(rem_atoms) + 1, alloc)
	append(&la_seq, ..rem_atoms)
	if anchored {
		append(&la_seq, new_node(Anchor_Kind.End, alloc))
	}

	la_node := new_node(
		Lookaround_Node{child = new_node(la_seq[:], alloc), positive = false, behind = false},
		alloc,
	)

	out := make([dynamic]^Node, 0, len(seq) + 1, alloc)
	append(&out, ..seq[:seq_idx])
	append(&out, la_node)
	append(&out, ..seq[seq_idx:])
	return new_node(out[:], alloc)
}

@(private = "file")
standard_classes :: proc(bm: Bitmap, alloc := context.temp_allocator) -> []Bitmap {
	lower, upper: Bitmap
	for c in u8('a') ..= u8('z') do bitmap_set(&lower, c)
	for c in u8('A') ..= u8('Z') do bitmap_set(&upper, c)
	alpha := bitmap_union(lower, upper)

	list := make([dynamic]Bitmap, 0, 5, alloc)
	if bitmap_is_subset(bm, BITMAP_DIGIT) do append(&list, BITMAP_DIGIT)
	if bitmap_is_subset(bm, lower) do append(&list, lower)
	if bitmap_is_subset(bm, upper) do append(&list, upper)
	if bitmap_is_subset(bm, alpha) do append(&list, alpha)
	if bitmap_is_subset(bm, BITMAP_WORD) do append(&list, BITMAP_WORD)
	return list[:]
}

@(private = "file")
replace_inner_bitmap :: proc(node: ^Node, bm: Bitmap, alloc := context.temp_allocator) -> ^Node {
	if r, ok := node.(Repeat_Node); ok {
		r.child = new_node(bm, alloc)
		return new_node(r, alloc)
	}
	return new_node(bm, alloc)
}

@(private = "file")
strip_repeat :: proc(node: ^Node) -> ^Node {
	if r, ok := node.(Repeat_Node); ok {
		return r.child
	}
	return node
}

@(private = "file")
is_alpha_class :: proc(bm: Bitmap) -> bool {
	lower, upper: Bitmap
	for c in u8('a') ..= u8('z') do bitmap_set(&lower, c)
	for c in u8('A') ..= u8('Z') do bitmap_set(&upper, c)
	return bm == lower || bm == upper || bm == bitmap_union(lower, upper)
}
