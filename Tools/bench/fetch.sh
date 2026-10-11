#!/bin/sh
# Downloads the bench meetings into $WAFFLE_BENCH: ICSI and AMI headset mixes with their word-level transcripts (CC BY 4.0, University of
# Edinburgh), then cuts the 10 minutes of each where the most people talk (prep.py) and makes the Opus 24 kbit/s copy. About 2 GB.
set -e
cd "$(dirname "$0")"
D="${WAFFLE_BENCH:?set WAFFLE_BENCH to a data dir}"; mkdir -p "$D/raw"
U=https://groups.inf.ed.ac.uk/ami
[ -d "$D/raw/icsi" ] || { curl -sSL -o "$D/raw/icsi.zip" $U/ICSICorpusAnnotations/ICSI_core_NXT.zip && unzip -qo "$D/raw/icsi.zip" -d "$D/raw/icsi"; }
[ -d "$D/raw/ami" ] || { curl -sSL -o "$D/raw/ami.zip" $U/AMICorpusAnnotations/ami_public_manual_1.6.2.zip && unzip -qo "$D/raw/ami.zip" 'words/*' -d "$D/raw/ami"; }
for m in Bmr009 Bro018 Bed008 Bmr006 Bmr013 Bmr001 Bed012 Bro027 Bed002 Bmr016 Bns001 Bmr007 Bmr019 Bmr024 ES2004a IS1009a; do
  [ -f "$D/$m-opus.wav" ] && continue
  case $m in
    ES*|IS*) [ -f "$D/raw/$m.wav" ] || curl -sSL -o "$D/raw/$m.wav" $U/AMICorpusMirror/amicorpus/$m/audio/$m.Mix-Headset.wav; words="$D/raw/ami/words/$m.*.words.xml" ;;
    *) [ -f "$D/raw/$m.wav" ] || curl -sSL -o "$D/raw/$m.wav" $U/ICSIsignals/NXT/$m.interaction.wav; words="$D/raw/icsi/ICSI/Words/$m.*.words.xml" ;;
  esac
  python3 -I prep.py "$words" "$D/raw/$m.wav" "$D/$m" > "$D/$m.off"
  ffmpeg -loglevel error -y -i "$D/$m.wav" -c:a libopus -b:a 24k "$D/$m.opus" && ffmpeg -loglevel error -y -i "$D/$m.opus" -ar 16000 -ac 1 "$D/$m-opus.wav" && rm "$D/$m.opus"
done
echo "ready: $D"
