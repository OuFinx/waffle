#!/usr/bin/env python3
"""Evaluates Waffle's live transcription windows on real speech.

Builds meeting-like streams from FLEURS recordings (two speakers: "mic" and "sys"), in several scenarios (dialogue, fast and slow
speakers, mid-sentence pauses, short replies, noise, a phone codec, echo of the far side in the mic, mixed languages), runs voice
detection (Silero) and the recognizer (Parakeet TDT 0.6B v3, sherpa-onnx) around Waffle's own window code (bridge, built from
Logic.swift), and compares with Waffle 0.3's windows (old/bridge) and with recognizing each utterance on its own (the best case).

Reports WER per speaker, how long words take to show up and to become final, and how much audio the recognizer had to process.
"""
import base64, json, math, os, random, re, subprocess, sys, time, unicodedata
import numpy as np, soundfile as sf, onnxruntime as ort, jiwer

ROOT = os.environ.get("WAFFLE_EVAL", "/tmp/waffle-eval")  # models, data and the built bridges (setup.sh puts them there)

SR, CHUNK = 16000, 4096
THREADS = int(os.environ.get("THREADS", "2"))

import sherpa_onnx
REC = sherpa_onnx.OfflineRecognizer.from_transducer(
    encoder=f"{ROOT}/models/pk3/encoder.int8.onnx", decoder=f"{ROOT}/models/pk3/decoder.int8.onnx", joiner=f"{ROOT}/models/pk3/joiner.int8.onnx",
    tokens=f"{ROOT}/models/pk3/tokens.txt", model_type="nemo_transducer", num_threads=THREADS)

def speech_level(x):
    n = 512
    if len(x) < n: return 0.0
    f = np.sqrt(np.mean(x[: len(x) // n * n].reshape(-1, n) ** 2, axis=1)); f.sort()
    return float(f[min(len(f) - 1, len(f) * 9 // 10)])

import agc as AGC
def recognize(x, level=True):
    """Tokens as Waffle gets them (Engine.transcribe): leveled, tried again when clear speech comes back empty."""
    if not level: return recognize_once(x)
    lx = AGC.agc(x)  # as Logic.swift's leveled()
    toks = recognize_once(lx)
    if toks or len(x) < SR or speech_level(lx) < 0.02: return toks
    again = recognize_once(lx + np.random.default_rng(len(x)).uniform(-3e-4, 3e-4, len(lx)).astype(np.float32))
    return again if again else recognize_once(x)

def recognize_once(x):
    if len(x) < SR // 2: x = np.concatenate([x, (np.random.randn(SR // 2 - len(x)) * 1e-4).astype(np.float32)])
    s = REC.create_stream(); s.accept_waveform(SR, x.astype(np.float32)); REC.decode_stream(s); r = s.result
    durs = list(r.durations) if r.durations else [0.08] * len(r.tokens)
    return [(float(t), float(t + d), tok) for tok, t, d in zip(r.tokens, r.timestamps, durs)]

# ---- voice detection: Silero v5, 512-sample frames, a chunk's probability is its loudest frame's (as FluidAudio's 4096-sample model)
VAD = ort.InferenceSession(f"{ROOT}/models/vad/silero.onnx", providers=["CPUExecutionProvider"])
class Vad:
    def __init__(self): self.state = np.zeros((2, 1, 128), np.float32); self.ctx = np.zeros(64, np.float32)
    def prob(self, chunk):
        best = 0.0
        for i in range(0, len(chunk), 512):
            f = chunk[i:i + 512]
            if len(f) < 512: break
            x = np.concatenate([self.ctx, f])[None, :].astype(np.float32)
            o, self.state = VAD.run(None, {"input": x, "state": self.state, "sr": np.array(SR, np.int64)})
            self.ctx = f[-64:]
            best = max(best, float(o[0][0]))
        return best

# ---- data
def load(lang):
    out = []
    for line in open(f"{ROOT}/data/{lang}/refs.tsv"):
        name, sid, gender, text = line.rstrip("\n").split("\t")
        x, sr = sf.read(f"{ROOT}/data/{lang}/{name}", dtype="float32")
        assert sr == SR
        out.append({"id": name, "text": text, "audio": x, "lang": lang})
    return out

CACHE = {}
RETRIES = []  # (thin passes tried bare, bare ones kept) per run
def words_of(u):
    """The utterance recognized on its own: its text (the best case) and its words' times."""
    key = (u["id"], u.get("variant", ""))
    if key not in CACHE:
        toks = recognize(u["audio"])
        ws = []
        for s, e, t in toks:
            if t.startswith(" ") or not ws: ws.append([s, e, t.strip()])
            else: ws[-1][1] = e; ws[-1][2] += t
        CACHE[key] = ("".join(t for _, _, t in toks).strip(), ws)
    return CACHE[key]

def tempo(x, f):
    if f == 1.0: return x
    p = subprocess.run(["ffmpeg", "-v", "quiet", "-f", "f32le", "-ar", str(SR), "-ac", "1", "-i", "-", "-filter:a", f"atempo={f}", "-f", "f32le", "-"], input=x.tobytes(), capture_output=True)
    return np.frombuffer(p.stdout, np.float32).copy()

def phone(x):
    """An Opus 16 kbit/s round trip at 16 kHz, band-limited like a call."""
    enc = subprocess.run(["ffmpeg", "-v", "quiet", "-f", "f32le", "-ar", str(SR), "-ac", "1", "-i", "-", "-af", "highpass=f=200,lowpass=f=3800", "-c:a", "libopus", "-b:a", "16k", "-f", "ogg", "-"], input=x.tobytes(), capture_output=True).stdout
    dec = subprocess.run(["ffmpeg", "-v", "quiet", "-i", "-", "-ar", str(SR), "-ac", "1", "-f", "f32le", "-"], input=enc, capture_output=True).stdout
    return np.frombuffer(dec, np.float32).copy()

def noise(n, rng):
    """Pink-ish room noise."""
    w = rng.standard_normal(n + 64).astype(np.float32)
    return np.convolve(w, np.ones(16) / 16, "same")[:n]

def rms(x): return float(np.sqrt(np.mean(x ** 2) + 1e-12))

# ---- scenarios: utterances placed on the two speakers' streams
def build(sc, utts, rng):
    """-> mic, sys streams and the placed utterances [(src, start sample, utt)]."""
    placed, t = [], int(SR * 1.0)
    for k, u in enumerate(utts):
        u = dict(u)
        src = sc.get("src", lambda k: "sys" if k % 2 == 0 else "mic")(k)
        if sc.get("tempo", 1.0) != 1.0:
            u["audio"] = tempo(u["audio"], sc["tempo"]); u["variant"] = f"tempo{sc['tempo']}"
        if sc.get("short") and src == "mic":
            _, ws = words_of(u)
            n = rng.integers(1, 4)
            if len(ws) > n:
                end = int((ws[n - 1][1] + 0.12) * SR)
                u["audio"] = u["audio"][:end]; u["variant"] = f"short{n}"
                u["text"] = " ".join(w[2] for w in ws[:n])  # the reference is what the model hears in those words
                u["ref_is_model"] = True
        if sc.get("normalize"):  # call apps even out the people's levels
            sp = u["audio"][np.abs(u["audio"]) > 1e-4]
            if len(sp): u["audio"] = (u["audio"] * (0.03 / rms(sp))).astype(np.float32); u["variant"] = u.get("variant", "") + "norm"
        if sc.get("pauses"):  # a slow speaker who stops mid-sentence
            _, ws = words_of(u)
            cuts = sorted(rng.choice(range(2, max(3, len(ws) - 2)), size=min(2, max(0, len(ws) - 4)), replace=False)) if len(ws) > 6 else []
            pieces, last = [], 0
            for c in cuts:
                at = int(((ws[c - 1][1] + ws[c][0]) / 2) * SR)
                pieces += [u["audio"][last:at], np.zeros(int(SR * rng.uniform(*sc["pauses"])), np.float32)]; last = at
            pieces.append(u["audio"][last:])
            u["audio"] = np.concatenate(pieces); u["variant"] = (u.get("variant", "") + "pause")
        placed.append((src, t, u))
        t += len(u["audio"]) + int(SR * rng.uniform(*sc["gaps"]))
    n = t + SR * 3
    mic, sys_ = np.zeros(n, np.float32), np.zeros(n, np.float32)
    for src, s, u in placed:
        (mic if src == "mic" else sys_)[s:s + len(u["audio"])] += u["audio"]
    if sc.get("phone"): sys_ = np.pad(phone(sys_), (0, 0))[:n]; sys_ = np.pad(sys_, (0, max(0, n - len(sys_))))
    if sc.get("snr"):
        for x, snr in ((sys_, sc["snr"]), (mic, sc["snr"] + 5)):
            speech = x[np.abs(x) > 1e-4]
            if len(speech): x += noise(n, rng) * (rms(speech) / 10 ** (snr / 20)) / max(rms(noise(SR, rng)), 1e-9)
    if sc.get("echo"):  # the far side leaking into the mic after echo cancellation: quieter, a little late, a bit distorted
        gain, delay = sc["echo"]
        leak = np.tanh(3 * np.roll(sys_, int(delay * SR))) / 3 * gain
        mic = mic + leak
    if not sc.get("snr"):  # a quiet room, never digital silence on the mic
        mic = mic + (rng.standard_normal(n) * 2e-4).astype(np.float32)
    return mic.astype(np.float32), sys_.astype(np.float32), placed

# ---- running a bridge
class Bridge:
    def __init__(self, path, args=()):
        self.p = subprocess.Popen([path, *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    def cmd(self, s):
        self.p.stdin.write(s + "\n"); self.p.stdin.flush()
        out = []
        while True:
            l = self.p.stdout.readline()
            if not l: raise RuntimeError("bridge died")
            l = l.rstrip("\n")
            if l == "OK": return out
            out.append(l)
    def close(self): self.p.stdin.close(); self.p.wait()

def b64(x): return base64.b64encode(x.astype(np.float32).tobytes()).decode()

def run(bridge_path, mic, sys_, old=False, echo_gate=False, rms_vad=False):
    """Feeds both speakers chunk by chunk, recognizes each pass one chunk later (as the app does, one pass at a time), and records
    when text shows up."""
    br = Bridge(bridge_path, ["--echo-gate"] if echo_gate else [])
    audio = {"mic": mic.copy(), "sys": sys_.copy()}
    vads = {"mic": Vad(), "sys": Vad()}
    speaking = {"mic": False, "sys": False}
    floor = {"mic": 0.001, "sys": 0.001}
    level = {"mic": 0.0, "sys": 0.0}
    queue, events, cost, npass = [], [], 0, 0
    old_mode, retries = old, [0, 0]
    def take(lines, now):
        nonlocal npass
        for l in lines:
            if l.startswith("P "):
                _, pid, src, final, start, count, ctx = l.split()
                queue.append((int(pid), src, int(start), int(count), now, int(ctx))); npass += 1
            elif l.startswith("E "):
                _, src, start, final, *text = l.split(" ", 4)
                events.append((now, src, int(start), final == "1", text[0] if text else ""))
    def work(now, upto=None):
        nonlocal cost
        while queue and (upto is None or queue[0][4] < upto):
            pid, src, start, count, _, ctx = queue.pop(0)
            x = audio[src][start:start + count]
            cost += count
            toks = recognize(x)
            if not old_mode:  # as Source.run: too few words for the speech, try without the context
                h = br.cmd(f"H {pid} {json.dumps(toks)}")[0].split()
                if h[1] == "1":
                    bare = recognize(x[ctx:]); cost += count - ctx; retries[0] += 1
                    if int(br.cmd(f"B {pid} {json.dumps(bare)}")[0].split()[1]) > int(int(h[2]) * 1.3):
                        br.cmd(f"X {pid}"); toks = bare; retries[1] += 1
            take(br.cmd(f"D {pid} {json.dumps(toks)}"), now)
    n = len(mic)
    for i in range(0, n - CHUNK + 1, CHUNK):
        now = (i + CHUNK) / SR
        work(now, upto=now)  # the passes asked for before this chunk
        for src in ("sys", "mic"):
            x = audio[src][i:i + CHUNK]
            if old:
                if src == "sys" and not np.any(x): take(br.cmd(f"I {src} {CHUNK}"), now); continue  # screen capture sends nothing while silent
                g = br.cmd(f"C {src} 1 {b64(x)}"); take(g[1:], now); continue
            r = rms(x)  # as Source.process: each piece at one level for the voice model, the room's noise floor kept down
            floor[src] = 0.9 * floor[src] + 0.1 * r if r < floor[src] else min(floor[src] * 1.01, 0.05)
            gain = min(20.0, 0.05 / max(r, 3 * floor[src], 0.0005))
            if rms_vad:
                p = 1.0 if r > max(0.0015, floor[src] * 3) else 0.0
            else:
                p = vads[src].prob(x * gain if abs(gain - 1) > 0.05 else x)
            speaking[src] = p >= 0.35 if speaking[src] else p >= 0.5
            g = br.cmd(f"C {src} {1 if speaking[src] else 0} {b64(x)}")
            if g[0] == "G 1": audio[src][i:i + CHUNK] = 0  # the echo check silenced it
            take(g[1:], now)
    end = n / SR
    work(end)
    for src in ("sys", "mic"): take(br.cmd(f"F {src}"), end)
    work(end); work(end)
    lines = json.loads(br.cmd("L")[0])
    br.close()
    RETRIES.append(tuple(retries))
    return lines, events, cost / SR, npass

# ---- scoring
def norm(s):
    s = unicodedata.normalize("NFKC", s).lower().replace("’", "'")
    s = "".join(c if c.isalnum() or c in " '" else " " for c in s)
    return " ".join(s.split())

def wer(ref, hyp):
    r, h = norm(ref), norm(hyp)
    if not r: return 0.0 if not h else 1.0
    return jiwer.wer(r, h)

def latency(events, placed):
    """Seconds from the end of a word (as said) to when it first shows, and to when it is final."""
    shown, final = {}, {}
    for now, src, start, fin, text in events:
        for w in norm(text).split():
            shown.setdefault((src, w), []).append(now)
            if fin: final.setdefault((src, w), []).append(now)
    show_lag, final_lag = [], []
    for src, s, u in placed:
        _, ws = words_of(u)
        for ws_, we, w in ws:
            k = (src, norm(w))
            end = s / SR + we
            a = [t for t in shown.get(k, []) if t >= end - 0.3]
            b = [t for t in final.get(k, []) if t >= end - 0.3]
            if a: show_lag.append(min(a) - end)
            if b: final_lag.append(min(b) - end)
    q = lambda v, p: float(np.percentile(v, p)) if v else float("nan")
    return q(show_lag, 50), q(show_lag, 90), q(final_lag, 50), q(final_lag, 90)

SCENARIOS = {
    "dialogue":     {"gaps": (0.3, 1.5)},
    "fast":         {"gaps": (0.05, 0.3), "tempo": 1.35, "src": lambda k: "sys"},
    "slow-pauses":  {"gaps": (0.8, 3.0), "tempo": 0.8, "pauses": (0.5, 1.4), "src": lambda k: "sys"},
    "short-replies": {"gaps": (0.15, 0.8), "short": True},
    "noisy":        {"gaps": (0.3, 1.5), "snr": 10, "normalize": True},
    "phone":        {"gaps": (0.3, 1.5), "phone": True, "normalize": True},
    "echo":         {"gaps": (0.3, 1.2), "short": True, "echo": (0.18, 0.06), "normalize": True},
    "echo-strong":  {"gaps": (0.3, 1.2), "short": True, "echo": (0.4, 0.03), "normalize": True},
}

def evaluate(lang, scen, n_utts=14, seed=1, modes=("offline", "new", "old")):
    rng = np.random.default_rng(seed)
    if lang == "mixed":
        a, b = load("uk_ua"), load("en_us")
        utts = [x for p in zip(a[:n_utts // 2], b[:n_utts // 2]) for x in p]
    else:
        utts = load(lang)[:n_utts]
    sc = SCENARIOS[scen]
    mic, sys_, placed = build(sc, utts, rng)
    secs = len(mic) / SR
    refs = {s: " ".join(u["text"] for src, _, u in placed if src == s) for s in ("mic", "sys")}
    res = {"lang": lang, "scenario": scen, "minutes": round(secs / 60, 2)}
    # the best case: each utterance on its own (the same model, perfect cuts)
    if "offline" in modes:
        stream = {"mic": mic, "sys": sys_}
        for s in ("mic", "sys"):
            # each utterance recognized on its own, from the stream as Waffle hears it (with the noise, the codec, the echo)
            hyp = " ".join("".join(t for _, _, t in recognize(stream[src][st:st + len(u["audio"])])).strip() for src, st, u in placed if src == s)
            res[f"offline_{s}"] = round(wer(refs[s], hyp), 4) if refs[s] else None
    for mode in modes:
        if mode == "offline": continue
        t0 = time.time()
        kw = {"old": mode == "old", "echo_gate": mode == "new" and scen.startswith("echo"), "rms_vad": mode == "new-rms"}
        lines, events, cost, npass = run(f"{ROOT}/old-bridge" if mode == "old" else f"{ROOT}/bridge", mic, sys_, **kw)
        for s in ("mic", "sys"):
            hyp = " ".join(l["text"] for l in sorted(lines, key=lambda l: l["t"]) if l["src"] == s)
            res[f"{mode}_{s}"] = round(wer(refs[s], hyp), 4) if refs[s] else (None if not hyp else f"extra:{hyp[:80]}")
        res[f"{mode}_retries"] = RETRIES[-1] if RETRIES else None
        show50, show90, fin50, fin90 = latency(events, placed)
        res[f"{mode}_show_p50"], res[f"{mode}_show_p90"] = round(show50, 2), round(show90, 2)
        res[f"{mode}_final_p50"], res[f"{mode}_final_p90"] = round(fin50, 2), round(fin90, 2)
        res[f"{mode}_asr_x"] = round(cost / secs, 2)  # seconds of audio recognized per second of meeting
        res[f"{mode}_passes_min"] = round(npass / (secs / 60), 1)
        res[f"{mode}_nonfinal"] = sum(1 for l in lines if not l["final"])
        res[f"{mode}_wall"] = round(time.time() - t0, 1)
    return res

if __name__ == "__main__":
    lang, scen = sys.argv[1], sys.argv[2]
    modes = tuple(sys.argv[3].split(",")) if len(sys.argv) > 3 else ("offline", "new", "old")
    r = evaluate(lang, scen, modes=modes)
    print(json.dumps(r, ensure_ascii=False))
    sys.stdout.flush()
