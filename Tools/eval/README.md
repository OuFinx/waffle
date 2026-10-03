# Live transcript evaluation

Runs Waffle's own window code (`Sources/Waffle/Logic.swift`, through `bridge.swift`) on real speech, next to how Waffle 0.3 did it
(`old/bridge.swift`) and next to recognizing each utterance on its own (the best the model can do with perfect cuts). The recognizer is
Parakeet TDT 0.6B v3 (int8, sherpa-onnx) and voice detection is Silero, so it runs anywhere, Linux included; `eval.py` mirrors what
`Recorder.swift` and `Engine.swift` do around the windows (voice detection at one level, the recognizer's input leveled, passes in order
one chunk late, the retry of thin passes). The app itself runs Parakeet "ultra" on the Neural Engine; CI checks that path with macOS's
own voices (`Sources/WaffleCheck`).

The meetings are built from FLEURS recordings (five languages), on two speakers ("mic" and "sys"):

| Scenario | What it tests |
|---|---|
| dialogue | turns between Me and Them, short pauses |
| fast | one fast speaker (1.35x), hardly any pauses |
| slow-pauses | a slow speaker (0.8x) who stops mid-sentence for up to 1.4 s |
| short-replies | Me answers in one to three words |
| noisy | room noise at 10 dB SNR |
| phone | Them through Opus 16 kbit/s, band-limited like a call |
| echo, echo-strong | the speakers coming back into the mic after echo cancellation |
| mixed | Ukrainian and English in one call |

FLEURS recordings vary in level by 30 dB, so quiet speakers right after loud ones come up too.

```sh
./setup.sh           # once: environment, models, data, bridges (in $WAFFLE_EVAL, default /tmp/waffle-eval)
./run.sh             # every scenario, then the table
python diag.py uk_ua slow-pauses 6   # where one run differs from recognizing each utterance alone
```
