#!/usr/bin/env bash
set -euo pipefail

# Resolve the Odin install root that mise pinned for this project.
ODIN_ROOT="$(mise where odin)"

# vendor:miniaudio ships only source; its static lib must be built once.
# Self-heal if it's missing (e.g. after an Odin reinstall).
if [ ! -f "$ODIN_ROOT/vendor/miniaudio/lib/miniaudio.a" ]; then
	echo "building vendor:miniaudio static lib..."
	ODIN_ROOT="$ODIN_ROOT" "$ODIN_ROOT/vendor/miniaudio/src/build_miniaudio.sh"
fi

# TinySoundFont ships as a single C header; build its static lib once.
if [ ! -f "tsf/libtsf.a" ]; then
	echo "building tsf static lib..."
	cc -c -O2 -fPIC tsf/tsf.c -o tsf/tsf.o
	ar rcs tsf/libtsf.a tsf/tsf.o
	rm -f tsf/tsf.o
fi

# raylib links the X11 stack + GL. On this Fedora Atomic (Bluefin) host the dev
# .so symlinks live under Homebrew, but Homebrew's ld doesn't search its own lib
# path by default. Point the linker at it and bake an rpath so the binary runs.
# -lm satisfies TinySoundFont's libm use.
BREW_LIB="/home/linuxbrew/.linuxbrew/lib"
LINK_FLAGS="-L${BREW_LIB} -Wl,-rpath,${BREW_LIB} -lm"

exec mise exec -- odin build . -out:guitar-trainer \
	-extra-linker-flags:"${LINK_FLAGS}" "$@"
