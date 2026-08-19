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
if [ ! -f "src/tsf/libtsf.a" ]; then
	echo "building tsf static lib..."
	cc -c -O2 -fPIC src/tsf/tsf.c -o src/tsf/tsf.o
	ar rcs src/tsf/libtsf.a src/tsf/tsf.o
	rm -f src/tsf/tsf.o
fi

# NeuralAmpModelerCore (C++); build its static lib once (fetches Eigen + json).
if [ ! -f "src/nam/libnam.a" ]; then
	echo "building nam (neural amp) static lib... (first time: clones Eigen, ~minutes)"
	bash src/nam/build.sh
fi

# raylib links the X11 stack + GL. On this Fedora Atomic (Bluefin) host the dev
# .so symlinks live under Homebrew, but Homebrew's ld doesn't search its own lib
# path by default. Point the linker at it and bake an rpath so the binary runs.
# -lm satisfies TinySoundFont; -lstdc++ the C++ neural-amp lib (src/nam/libnam.a).
BREW_LIB="/home/linuxbrew/.linuxbrew/lib"
LINK_FLAGS="-L${BREW_LIB} -Wl,-rpath,${BREW_LIB} -lm -lstdc++"

# The application (package main) lives in src/. The binary lands at the repo
# root so `./guitar-trainer` runs with assets/ resolvable via relative paths.
exec mise exec -- odin build src -out:guitar-trainer -o:speed \
	-extra-linker-flags:"${LINK_FLAGS}" "$@"
