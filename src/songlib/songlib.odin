package songlib

// Pure logic for the song-import flow (no I/O): parsing the separator
// subprocess's stdout lines, filtering source files by audio extension, turning
// a filename into a library folder slug, and deciding whether a library subdir
// holds a finished 6-stem separation. All allocation-free (slug writes into a
// caller-supplied buffer); the I/O shell lives in src/import.odin.

import "core:strings"
import "core:strconv"

// The 6 stems Demucs' htdemucs_6s model produces, in a fixed order.
STEMS :: [6]string{"vocals", "drums", "bass", "guitar", "piano", "other"}

Kind :: enum {
	Unknown,
	Progress,
	Done,
	Error,
}

// One parsed line of separate.py's stdout. `text` for Done/Error is a subslice of
// the input line (no allocation); `pct` is meaningful only for Progress.
Progress_Msg :: struct {
	kind: Kind,
	pct:  int,
	text: string,
}

// parse_line reads one separator stdout line: "PROGRESS <n>", "DONE <path>",
// "ERROR <msg>", anything else -> Unknown. Progress pct is clamped to [0,100].
parse_line :: proc(line: string) -> Progress_Msg {
	s := strings.trim_space(line)
	if strings.has_prefix(s, "PROGRESS ") {
		n, parsed := strconv.parse_int(strings.trim_space(s[len("PROGRESS "):]))
		if !parsed do return {kind = .Unknown}
		return {kind = .Progress, pct = clamp(n, 0, 100)}
	}
	if strings.has_prefix(s, "DONE ") {
		return {kind = .Done, text = strings.trim_space(s[len("DONE "):])}
	}
	if strings.has_prefix(s, "ERROR ") {
		return {kind = .Error, text = strings.trim_space(s[len("ERROR "):])}
	}
	return {kind = .Unknown}
}

// is_supported_audio reports whether `name` has an extension we can import.
// Case-insensitive; a name that is all extension (".mp3") has no stem and fails.
is_supported_audio :: proc(name: string) -> bool {
	dot := strings.last_index_byte(name, '.')
	if dot <= 0 do return false // no dot, or dot at index 0 (dotfile, no stem)
	ext := name[dot + 1:]
	for want in ([]string{"wav", "flac", "mp3", "ogg", "m4a"}) {
		if strings.equal_fold(ext, want) do return true
	}
	return false
}

// slug turns a source filename into a library folder name: drop the extension,
// lowercase, map any run of non-alphanumeric chars to a single '-', and trim
// leading/trailing '-'. Writes into `buf` and returns the slice used.
slug :: proc(name: string, buf: []u8) -> string {
	stem := name
	if dot := strings.last_index_byte(name, '.'); dot > 0 {
		stem = name[:dot]
	}
	n := 0
	prev_dash := true // treat start as a boundary so we never emit a leading '-'
	for i := 0; i < len(stem) && n < len(buf); i += 1 {
		c := stem[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		is_alnum := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
		if is_alnum {
			buf[n] = c
			n += 1
			prev_dash = false
		} else if !prev_dash {
			buf[n] = '-'
			n += 1
			prev_dash = true
		}
	}
	for n > 0 && buf[n - 1] == '-' { // trim trailing dash
		n -= 1
	}
	return string(buf[:n])
}

// is_song_dir reports whether a directory listing contains all 6 stem WAVs, i.e.
// a finished separation. `entries` are bare file names (not paths).
is_song_dir :: proc(entries: []string) -> bool {
	for stem in STEMS {
		found := false
		for e in entries {
			// e == stem + ".wav", without allocating the concatenation.
			if strings.has_suffix(e, ".wav") && e[:len(e) - 4] == stem {
				found = true
				break
			}
		}
		if !found do return false
	}
	return true
}
