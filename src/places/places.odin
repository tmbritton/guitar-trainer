package places

// Pure parsing for the import browser's "Places" jump list: turning the
// contents of /proc/mounts into the handful of mount points worth offering as
// shortcuts (external disks, USB media, NAS shares). No I/O — src/places.odin
// reads the file and supplies the text.
//
// Allocation-free: returned strings are subslices of the caller's buffer, except
// where a mount point needs unescaping, which writes into a caller-supplied
// buffer.

import "core:strings"

// Directories under which a mount is worth showing. Everything else (/, /proc,
// /sys, /boot, overlay and container plumbing) is noise in a file browser.
// /var/mnt is included because image-based distros symlink /mnt there.
PREFIXES :: [4]string{"/mnt/", "/media/", "/run/media/", "/var/mnt/"}

// Filesystems that never hold user media, even under the prefixes above.
//
// autofs is deliberately NOT skipped. An idle automounted share appears only as
// an autofs entry — the CIFS/NFS mount it triggers exists in /proc/mounts just
// while something holds it open. Skipping autofs therefore hid exactly the NAS
// shares Places exists to reach, whenever they happened to be idle. When both
// entries are present they share a mount point, and places_list de-dupes by path.
SKIP_FSTYPES :: [2]string{"tmpfs", "devtmpfs"}

// is_automount reports an autofs entry, whose mount point directory exists
// without the backing filesystem being connected. Callers must not stat it to
// check liveness: on a direct automount that triggers the mount, which blocks
// until the share answers (or times out) if the server is unreachable.
is_automount :: proc(fstype: string) -> bool {
	return fstype == "autofs"
}

Mount :: struct {
	dir:    string, // mount point, still escape-encoded (see unescape)
	fstype: string,
}

// is_interesting reports whether a mount point should appear in Places.
is_interesting :: proc(dir, fstype: string) -> bool {
	for skip in SKIP_FSTYPES {
		if fstype == skip do return false
	}
	for p in PREFIXES {
		// Require something after the prefix, so "/mnt" itself isn't offered.
		if strings.has_prefix(dir, p) && len(dir) > len(p) do return true
	}
	return false
}

// parse_line pulls the mount point and fstype out of one /proc/mounts line
// ("<device> <dir> <fstype> <options> <dump> <pass>"). ok is false for a line
// that is blank or too short to be a mount entry.
parse_line :: proc(line: string) -> (m: Mount, ok: bool) {
	s := strings.trim_space(line)
	if len(s) == 0 do return {}, false
	field :: proc(s: string, n: int) -> (string, bool) {
		rest := s
		for i in 0 ..= n {
			sp := strings.index_byte(rest, ' ')
			if i == n {
				return (sp < 0 ? rest : rest[:sp]), len(rest) > 0
			}
			if sp < 0 do return "", false
			rest = rest[sp + 1:]
		}
		return "", false
	}
	dir := field(s, 1) or_return
	fstype := field(s, 2) or_return
	if len(dir) == 0 || len(fstype) == 0 do return {}, false
	return Mount{dir = dir, fstype = fstype}, true
}

// unescape decodes /proc/mounts octal escapes (a space is written "\040", so a
// path like "/mnt/My Disk" arrives as "/mnt/My\040Disk"). Writes into `buf` and
// returns the slice used; input without escapes is copied through unchanged.
unescape :: proc(s: string, buf: []u8) -> string {
	n := 0
	for i := 0; i < len(s) && n < len(buf); {
		if s[i] == '\\' && i + 3 < len(s) && is_octal(s[i + 1]) && is_octal(s[i + 2]) && is_octal(s[i + 3]) {
			v := (int(s[i + 1] - '0') << 6) | (int(s[i + 2] - '0') << 3) | int(s[i + 3] - '0')
			buf[n] = u8(v)
			n += 1
			i += 4
			continue
		}
		buf[n] = s[i]
		n += 1
		i += 1
	}
	return string(buf[:n])
}

@(private = "file")
is_octal :: proc(c: u8) -> bool {
	return c >= '0' && c <= '7'
}

// label is the short name shown for a mount point: its last path component,
// which is what a person recognises ("RAID", "My Passport").
label :: proc(dir: string) -> string {
	end := len(dir)
	for end > 1 && dir[end - 1] == '/' do end -= 1
	if slash := strings.last_index_byte(dir[:end], '/'); slash >= 0 && slash + 1 < end {
		return dir[slash + 1:end]
	}
	return dir[:end]
}
