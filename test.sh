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

# Homebrew lib path so packages that link system libs (e.g. store -> sqlite3)
# resolve at test-link time. Harmless for the pure packages.
BREW_LIB="/home/linuxbrew/.linuxbrew/lib"
LINK_FLAGS="-L${BREW_LIB} -Wl,-rpath,${BREW_LIB}"

packages=(clock ring detect rtalloc calib music game store amp)
fail=0
for pkg in "${packages[@]}"; do
	compgen -G "$pkg/*.odin" >/dev/null || continue # package not created yet
	printf '=== %-8s ' "$pkg"
	out="$(mise exec -- odin test "$pkg" -extra-linker-flags:"${LINK_FLAGS}" 2>&1)"
	if echo "$out" | grep -q "All tests were successful"; then
		echo "$out" | grep -oE "Finished [0-9]+ tests.*successful\."
	else
		echo "FAILED"
		echo "$out" | tail -20
		fail=1
	fi
done
exit $fail
