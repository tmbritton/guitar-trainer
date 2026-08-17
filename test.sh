#!/usr/bin/env bash
set -uo pipefail

# Run the unit tests for every pure-logic package. These need no hardware and no
# X11/GL, so no extra linker flags. The top-level `package main` (audio/raylib)
# is exercised by the headless self-tests instead: `./guitar-trainer --audiocheck`
# and `--calibcheck`.

ODIN_ROOT="$(mise where odin)"
if [ ! -f "$ODIN_ROOT/vendor/miniaudio/lib/miniaudio.a" ]; then
	ODIN_ROOT="$ODIN_ROOT" "$ODIN_ROOT/vendor/miniaudio/src/build_miniaudio.sh"
fi

packages=(clock ring detect rtalloc calib)
fail=0
for pkg in "${packages[@]}"; do
	printf '=== %-8s ' "$pkg"
	out="$(mise exec -- odin test "$pkg" 2>&1)"
	if echo "$out" | grep -q "All tests were successful"; then
		echo "$out" | grep -oE "Finished [0-9]+ tests.*successful\."
	else
		echo "FAILED"
		echo "$out" | tail -20
		fail=1
	fi
done
exit $fail
