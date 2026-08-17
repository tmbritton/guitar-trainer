package main

// audioprobe — standalone throwaway tool (Epic 0 / Story 3).
//
// Enumerates the audio devices miniaudio can see and reports the active
// backend. It does NOT open a device or run a callback — enumeration only.
// Used to confirm a duplex-capable capture device exists before Epic 1 owns a
// real ma_device.

import "core:fmt"
import ma "vendor:miniaudio"

cstr :: proc(buf: ^[ma.MAX_DEVICE_NAME_LENGTH + 1]u8) -> string {
	return string(cstring(raw_data(buf[:])))
}

main :: proc() {
	ctx: ma.context_type
	if ma.context_init(nil, 0, nil, &ctx) != .SUCCESS {
		fmt.eprintln("failed to init miniaudio context")
		return
	}
	defer ma.context_uninit(&ctx)

	fmt.printfln("miniaudio %s", ma.version_string())
	fmt.printfln("backend:   %v", ctx.backend)

	playback: [^]ma.device_info
	capture: [^]ma.device_info
	playback_count, capture_count: u32

	if ma.context_get_devices(&ctx, &playback, &playback_count, &capture, &capture_count) != .SUCCESS {
		fmt.eprintln("failed to enumerate devices")
		return
	}

	fmt.printfln("\nplayback devices (%d):", playback_count)
	for i in 0 ..< playback_count {
		d := &playback[i]
		fmt.printfln("  [%d] %-40s%s", i, cstr(&d.name), d.isDefault ? "  (default)" : "")
	}

	fmt.printfln("\ncapture devices (%d):", capture_count)
	for i in 0 ..< capture_count {
		d := &capture[i]
		fmt.printfln("  [%d] %-40s%s", i, cstr(&d.name), d.isDefault ? "  (default)" : "")
	}
}
