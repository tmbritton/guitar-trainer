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

# Extra lib path so packages that link system libs (e.g. store -> sqlite3)
# resolve at test-link time; see build.sh. Harmless for the pure packages, and
# inert if the path doesn't exist. Keep in sync with build.sh's BREW_LIB.
BREW_LIB="/home/linuxbrew/.linuxbrew/lib"
LINK_FLAGS="-L${BREW_LIB} -Wl,-rpath,${BREW_LIB}"

packages=(clock ring detect rtalloc calib music game store amp conv menu songlib pcmring mix ampchain places sections keyrepeat)
fail=0
for pkg in "${packages[@]}"; do
	dir="src/$pkg"
	compgen -G "$dir/*.odin" >/dev/null || continue # package not created yet
	printf '=== %-8s ' "$pkg"
	out="$(mise exec -- odin test "$dir" -extra-linker-flags:"${LINK_FLAGS}" 2>&1)"
	if echo "$out" | grep -q "All tests were successful"; then
		echo "$out" | grep -oE "Finished [0-9]+ tests.*successful\."
	else
		echo "FAILED"
		echo "$out" | tail -20
		fail=1
	fi
done
exit $fail
