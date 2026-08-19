package main

// Audio-device selection. The Rocksmith Real Tone cable is input-only, so the
// single duplex ma_device must bind capture (the cable) and playback (speakers)
// to *different* devices. We own an ma_context to enumerate devices and bind
// chosen IDs (nil = system default). Selection persists by name (audioconf.odin)
// and, absent a saved choice, auto-detects a Rocksmith/guitar capture device.

import "core:strings"

import ma "vendor:miniaudio"

import "clock"

MAX_DEVICES :: 16

Audio_Device :: struct {
	name:       string, // view into name_buf
	name_buf:   [128]u8,
	id:         ma.device_id,
	is_default: bool,
}

g_context: ma.context_type
g_context_ok: bool
g_capture_devs: [MAX_DEVICES]Audio_Device
g_capture_count: int
g_playback_devs: [MAX_DEVICES]Audio_Device
g_playback_count: int
g_sel_capture := -1 // index into g_capture_devs, or -1 for system default
g_sel_playback := -1

// audiodev_init_context creates the enumeration context and lists devices.
// Best-effort: on failure the device path falls back to nil (system default).
audiodev_init_context :: proc() -> bool {
	if ma.context_init(nil, 0, nil, &g_context) != .SUCCESS do return false
	g_context_ok = true
	audio_enumerate()
	return true
}

audiodev_uninit_context :: proc() {
	if g_context_ok {
		ma.context_uninit(&g_context)
		g_context_ok = false
	}
}

audio_enumerate :: proc() {
	if !g_context_ok do return
	pPlayback, pCapture: [^]ma.device_info
	pbCount, capCount: u32
	if ma.context_get_devices(&g_context, &pPlayback, &pbCount, &pCapture, &capCount) != .SUCCESS do return
	g_playback_count = copy_devs(g_playback_devs[:], pPlayback, int(pbCount))
	g_capture_count = copy_devs(g_capture_devs[:], pCapture, int(capCount))
}

@(private = "file")
copy_devs :: proc(dst: []Audio_Device, src: [^]ma.device_info, n: int) -> int {
	m := min(n, len(dst))
	for i in 0 ..< m {
		info := &src[i]
		dst[i].id = info.id
		dst[i].is_default = bool(info.isDefault)
		name := string(cstring(&info.name[0]))
		k := copy(dst[i].name_buf[:], name)
		dst[i].name = string(dst[i].name_buf[:k])
	}
	return m
}

audio_capture_devices :: proc() -> []Audio_Device {return g_capture_devs[:g_capture_count]}
audio_playback_devices :: proc() -> []Audio_Device {return g_playback_devs[:g_playback_count]}
audio_selected_capture :: proc() -> int {return g_sel_capture}
audio_selected_playback :: proc() -> int {return g_sel_playback}

// audio_resolve_selection picks the capture/playback devices at startup: a
// name saved in the config (if still present), else — for capture — a
// Rocksmith/guitar auto-detect, else the system default (-1).
audio_resolve_selection :: proc() {
	cap_name, pb_name := audioconf_load()
	g_sel_capture = resolve_capture(cap_name)
	g_sel_playback = resolve_by_name(g_playback_devs[:g_playback_count], pb_name)
}

@(private = "file")
resolve_by_name :: proc(devs: []Audio_Device, name: string) -> int {
	if name == "" do return -1
	for d, i in devs do if d.name == name do return i
	return -1
}

@(private = "file")
resolve_capture :: proc(name: string) -> int {
	if i := resolve_by_name(g_capture_devs[:g_capture_count], name); i >= 0 do return i
	if name != "" do return -1 // a saved name that's no longer present -> default
	for d, i in g_capture_devs[:g_capture_count] { // auto-detect a guitar interface
		if name_looks_like_guitar(d.name) do return i
	}
	return -1
}

// name_looks_like_guitar matches the Rocksmith Real Tone cable and similar
// guitar interfaces by name (case-insensitive).
name_looks_like_guitar :: proc(name: string) -> bool {
	lower := strings.to_lower(name, context.temp_allocator)
	return strings.contains(lower, "rocksmith") || strings.contains(lower, "real tone") || strings.contains(lower, "guitar")
}

// audio_reinit rebinds the duplex device to the given capture/playback indices
// (-1 = default) and persists the choice by name. Main-thread only; call it only
// when no producer/drill is running (from Settings).
audio_reinit :: proc(cap_idx, pb_idx: int) -> bool {
	ma.device_stop(&g_device)
	ma.device_uninit(&g_device)
	g_sel_capture = clamp_sel(cap_idx, g_capture_count)
	g_sel_playback = clamp_sel(pb_idx, g_playback_count)
	ok := device_open()
	audioconf_save(sel_name(g_capture_devs[:g_capture_count], g_sel_capture), sel_name(g_playback_devs[:g_playback_count], g_sel_playback))
	return ok
}

@(private = "file")
clamp_sel :: proc(idx, count: int) -> int {
	return (idx >= 0 && idx < count) ? idx : -1
}

@(private = "file")
sel_name :: proc(devs: []Audio_Device, idx: int) -> string {
	return (idx >= 0 && idx < len(devs)) ? devs[idx].name : ""
}

// device_open builds the duplex config from the current selection and starts the
// device. Shared by audio_init and audio_reinit.
device_open :: proc() -> bool {
	cfg := ma.device_config_init(.duplex)
	cfg.sampleRate = clock.SAMPLE_RATE
	cfg.periodSizeInFrames = PERIOD_FRAMES
	cfg.capture.format = .f32
	cfg.capture.channels = 1
	cfg.playback.format = .f32
	cfg.playback.channels = 1
	cfg.dataCallback = audio_callback
	if g_sel_capture >= 0 do cfg.capture.pDeviceID = &g_capture_devs[g_sel_capture].id
	if g_sel_playback >= 0 do cfg.playback.pDeviceID = &g_playback_devs[g_sel_playback].id

	ctx := g_context_ok ? &g_context : nil
	if ma.device_init(ctx, &cfg, &g_device) != .SUCCESS do return false
	if ma.device_start(&g_device) != .SUCCESS {
		ma.device_uninit(&g_device)
		return false
	}
	return true
}
