package grepback

import "core:math/bits"

// 256-bit ASCII bitmap: word = b >> 6, bit = b & 63
Bitmap :: [4]u64

bitmap_count :: proc(bm: Bitmap) -> int {
	return int(
		bits.count_ones(bm[0]) +
		bits.count_ones(bm[1]) +
		bits.count_ones(bm[2]) +
		bits.count_ones(bm[3]),
	)
}

bitmap_set :: proc(bm: ^Bitmap, b: u8) {
	bm[b >> 6] |= (u64(1) << (b & 63))
}

bitmap_set_range :: proc(bm: ^Bitmap, lo, hi: u8) {
	for b in lo ..= hi {
		bitmap_set(bm, b)
	}
}

bitmap_has :: proc(bm: Bitmap, b: u8) -> bool {
	return (bm[b >> 6] & (u64(1) << (b & 63))) != 0
}

bitmap_union :: proc(a, b: Bitmap) -> Bitmap {
	return {a[0] | b[0], a[1] | b[1], a[2] | b[2], a[3] | b[3]}
}

bitmap_invert :: proc(a: Bitmap) -> Bitmap {
	return {~a[0], ~a[1], ~a[2], ~a[3]}
}

BITMAP_DIGIT :: Bitmap {
	0x03FF_0000_0000_0000, // '0'..'9' (48..57)
	0,
	0,
	0,
}

BITMAP_LOWER :: Bitmap {
	0,
	0x07FF_FFFE_0000_0000, // 'a'..'z' (97..122)
	0,
	0,
}

BITMAP_UPPER :: Bitmap {
	0,
	0x0000_0000_07FF_FFFE, // 'A'..'Z' (65..90)
	0,
	0,
}

BITMAP_WORD :: Bitmap {
	BITMAP_DIGIT[0],
	BITMAP_UPPER[1] | BITMAP_LOWER[1] | (u64(1) << ('_' & 63)),
	0,
	0,
}

BITMAP_SPACE :: Bitmap {
	(1 << ' ') | (1 << '\t') | (1 << '\n') | (1 << '\r') | (1 << '\v') | (1 << '\f'),
	0,
	0,
	0,
}

BITMAP_ANY :: Bitmap{~u64(1 << '\n'), ~u64(0), ~u64(0), ~u64(0)}
