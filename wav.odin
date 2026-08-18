package main

// Minimal mono 16-bit PCM WAV writer — for exporting rendered audio so it can
// be auditioned/scrubbed outside the app (a way to verify audio work).

import "core:os"

@(private = "file")
put_u32 :: proc(b: ^[dynamic]u8, v: u32) {
	append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}
@(private = "file")
put_u16 :: proc(b: ^[dynamic]u8, v: u16) {
	append(b, u8(v), u8(v >> 8))
}
@(private = "file")
put_str :: proc(b: ^[dynamic]u8, s: string) {
	for c in transmute([]u8)s {
		append(b, c)
	}
}

// write_wav writes `samples` (mono f32 in [-1,1]) as a 16-bit PCM WAV at `rate`.
write_wav :: proc(path: string, samples: []f32, rate: u32 = 48000) -> bool {
	data_bytes := u32(len(samples) * 2)
	b := make([dynamic]u8, 0, 44 + int(data_bytes))
	defer delete(b)

	put_str(&b, "RIFF");put_u32(&b, 36 + data_bytes);put_str(&b, "WAVE")
	put_str(&b, "fmt ");put_u32(&b, 16);put_u16(&b, 1);put_u16(&b, 1) // PCM, mono
	put_u32(&b, rate);put_u32(&b, rate * 2);put_u16(&b, 2);put_u16(&b, 16)
	put_str(&b, "data");put_u32(&b, data_bytes)
	for s in samples {
		v := clamp(s, -1, 1) * 32767
		put_u16(&b, u16(i16(v)))
	}
	return os.write_entire_file(path, b[:]) == nil
}
