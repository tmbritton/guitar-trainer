#!/usr/bin/env bash
set -euo pipefail
# Download the guitar SoundFonts the app A/Bs between. These are third-party
# free soundfonts from zanderjaz.com — check their licensing for your use.
# They are NOT committed to the repo (binary, large); run this to fetch them.
cd "$(dirname "$0")"
base="https://www.zanderjaz.com/soundfonts/guitars"

dl() { # local url
	if [ -f "$1" ]; then echo "have $1"; return; fi
	echo "fetching $1 ..."
	curl -sL -o "$1" "$base/$2"
	[ "$(head -c4 "$1")" = "RIFF" ] || { echo "  WARN: $1 is not a valid SF2"; }
}

dl electric.sf2  "Electric_guitar.SF2"    # 1 preset: Electric_Guitar
dl rock60s.sf2   "60s_Rock_Guitar.SF2"    # Clean + Overdriven L/M/H
dl power.sf2     "Power%20Guitar%201.sf2" # Power Guitar 1
dl dethmetal.sf2 "Dethmetal.SF2"          # Distorted / Clean / Chords / Bass
echo "done."
