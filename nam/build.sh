#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Build libnam.a: NeuralAmpModelerCore + our C shim. Header-only deps (Eigen +
# nlohmann/json) are fetched here, not committed. Compiled with NAM_SAMPLE_FLOAT
# so the model processes float buffers.
V=vendor
mkdir -p "$V"

[ -d "$V/namcore" ] || git clone --depth 1 -q https://github.com/sdatkinson/NeuralAmpModelerCore "$V/namcore"
[ -d "$V/eigen" ]   || git clone --depth 1 -q https://gitlab.com/libeigen/eigen "$V/eigen"

CORE="$V/namcore/NAM"
# nam_file.h does #include "json.hpp" — put it next to the core headers.
[ -f "$CORE/json.hpp" ] || curl -sL -o "$CORE/json.hpp" \
	https://raw.githubusercontent.com/nlohmann/json/develop/single_include/nlohmann/json.hpp

INC="-I $V/namcore -I $CORE -I $V/eigen"
# Aggressive optimization — neural-amp inference is the bottleneck. -march=native
# is fine for this single-machine personal tool.
FLAGS="-std=c++17 -O3 -march=native -ffast-math -funroll-loops -DNDEBUG -fPIC -DNAM_SAMPLE_FLOAT"

rm -rf obj && mkdir -p obj
objs=()
for f in "$CORE"/*.cpp "$CORE"/wavenet/*.cpp nam_shim.cpp; do
	o="obj/$(basename "${f%.cpp}").o"
	c++ $FLAGS $INC -c "$f" -o "$o"
	objs+=("$o")
done
# Combine into ONE relocatable object so the architecture parsers' static
# registrations (e.g. _register_WaveNet in model.cpp) aren't dropped by the
# linker — referencing nam_load then pulls the whole thing in.
ld -r -o obj/nam_all.o "${objs[@]}"
rm -f libnam.a && ar rcs libnam.a obj/nam_all.o
rm -rf obj
echo "built nam/libnam.a"
