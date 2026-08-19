package main

// Load a separated song's stems for playback: decode each of the 6 stem WAVs to
// mono f32 @ 48 kHz (the device's format) via miniaudio's decoder — the same
// pattern as ir.odin, but sized to the whole file (a full song, tens of MB per
// stem). Heap-allocated, loaded/freed on the main thread; never touched on the
// audio callback (the producer thread reads it, the callback only drains the ring).

import "core:fmt"
import "core:strings"

import ma "vendor:miniaudio"

import "mix"
import "songlib"

// Song_Audio holds every stem's mono PCM plus its mixer control. `frames` is the
// longest stem (the song length); shorter/absent stems are treated as silent past
// their end.
Song_Audio :: struct {
	stems:  [6][]f32,
	ctl:    [6]mix.Stem_Ctl,
	frames: int,
}

// stems_load decodes the 6 stems under `dir`. Missing/undecodable stems load as
// silent (nil). ok is false only if not a single stem decoded.
stems_load :: proc(dir: string) -> (sa: Song_Audio, ok: bool) {
	for stem, i in songlib.STEMS {
		sa.ctl[i] = mix.Stem_Ctl{level = 1}
		path := fmt.tprintf("%s/%s.wav", dir, stem)
		if pcm, dok := decode_mono(path); dok {
			sa.stems[i] = pcm
			sa.frames = max(sa.frames, len(pcm))
		}
	}
	return sa, sa.frames > 0
}

stems_free :: proc(sa: ^Song_Audio) {
	for &s in sa.stems {
		if s != nil {
			delete(s)
			s = nil
		}
	}
	sa.frames = 0
}

// decode_mono decodes any-format audio at `path` to mono f32 @ 48 kHz into a
// freshly allocated slice.
@(private = "file")
decode_mono :: proc(path: string) -> ([]f32, bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	cfg := ma.decoder_config_init(.f32, 1, 48000)
	dec: ma.decoder
	if ma.decoder_init_file(cpath, &cfg, &dec) != .SUCCESS do return nil, false
	defer ma.decoder_uninit(&dec)

	length: u64
	if ma.decoder_get_length_in_pcm_frames(&dec, &length) != .SUCCESS || length == 0 {
		return nil, false
	}
	pcm := make([]f32, int(length))
	read: u64
	ma.decoder_read_pcm_frames(&dec, raw_data(pcm), length, &read)
	if read == 0 {
		delete(pcm)
		return nil, false
	}
	return pcm[:int(read)], true
}
