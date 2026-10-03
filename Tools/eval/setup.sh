#!/bin/sh
# Sets up the evaluation in $WAFFLE_EVAL (default /tmp/waffle-eval): a Python environment, Parakeet TDT 0.6B v3 (int8, sherpa-onnx) and
# Silero VAD, 80 FLEURS recordings per language, and the two bridges (Waffle's window code now, and as 0.3 had it). Linux or macOS;
# needs python3, ffmpeg with libopus, curl and swiftc.
set -e
cd "$(dirname "$0")"
ROOT="${WAFFLE_EVAL:-/tmp/waffle-eval}"
mkdir -p "$ROOT/models/pk3" "$ROOT/models/vad" "$ROOT/data"
python3 -m venv "$ROOT/env"
"$ROOT/env/bin/pip" install -q sherpa-onnx onnxruntime soundfile numpy jiwer
HF=https://huggingface.co
for f in encoder.int8.onnx decoder.int8.onnx joiner.int8.onnx tokens.txt; do
  [ -f "$ROOT/models/pk3/$f" ] || curl -sSL -o "$ROOT/models/pk3/$f" "$HF/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main/$f"
done
[ -f "$ROOT/models/vad/silero.onnx" ] || curl -sSL -o "$ROOT/models/vad/silero.onnx" "$HF/onnx-community/silero-vad/resolve/main/onnx/model.onnx"
for l in uk_ua en_us ru_ru pl_pl de_de; do [ -f "$ROOT/data/$l/refs.tsv" ] || WAFFLE_EVAL="$ROOT" "$ROOT/env/bin/python" fetch.py $l 80; done
swiftc -O -swift-version 5 ../../Sources/Waffle/Logic.swift bridge.swift -o "$ROOT/bridge"
mkdir -p "$ROOT/old"
git show 46e6ab8:Sources/Waffle/Logic.swift > "$ROOT/old/Logic.swift"
cp old/bridge.swift "$ROOT/old/main.swift"
swiftc -O -swift-version 5 "$ROOT/old/Logic.swift" "$ROOT/old/main.swift" -o "$ROOT/old-bridge"
echo "ready: $ROOT"
