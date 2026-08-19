#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Build libsoundtouch.a: the SoundTouch WSOLA time-stretch library (LGPL C++) +
# our C shim (st_shim.cpp). The source is fetched here, not committed. Compiled
# with SOUNDTOUCH_FLOAT_SAMPLES so it processes float buffers (the app is float).
V=vendor
mkdir -p "$V"

[ -d "$V/soundtouch" ] || git clone --depth 1 -q https://codeberg.org/soundtouch/soundtouch "$V/soundtouch"

SRC="$V/soundtouch/source/SoundTouch"
INC="-I $V/soundtouch/include -I $SRC"
FLAGS="-std=c++17 -O2 -fPIC -DNDEBUG -DSOUNDTOUCH_FLOAT_SAMPLES=1"

rm -rf obj && mkdir -p obj
objs=()
for f in "$SRC"/*.cpp st_shim.cpp; do
	o="obj/$(basename "${f%.cpp}").o"
	c++ $FLAGS $INC -c "$f" -o "$o"
	objs+=("$o")
done
rm -f libsoundtouch.a && ar rcs libsoundtouch.a "${objs[@]}"
rm -rf obj
echo "built src/soundtouch/libsoundtouch.a"
