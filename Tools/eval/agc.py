import numpy as np
def agc(x, target=0.08, most=30.0, reach=8):
    """Gain that follows the speech level around each 32 ms frame (the loudest within +-reach frames), smoothed, never clipping."""
    n = 512
    if len(x) < n: return x
    m = len(x) // n
    f = np.sqrt(np.mean(x[: m * n].reshape(-1, n) ** 2, axis=1))
    if len(x) > m * n: f = np.append(f, np.sqrt(np.mean(x[m * n:] ** 2)))
    env = np.array([f[max(0, i - reach): i + reach + 1].max() for i in range(len(f))])
    peak = np.array([np.abs(x[max(0, (i - reach) * n): (i + reach + 1) * n]).max() for i in range(len(f))])
    noise = np.sort(f)[len(f) // 10]  # the quiet between words: never brought above a quarter of the speech level
    g = np.minimum(np.minimum(np.minimum(most, target / np.maximum(env, 1e-5)), 0.99 / np.maximum(peak, 1e-9)), target / 4 / max(noise, 1e-6))
    g = np.convolve(np.pad(g, 2, mode="edge"), np.ones(5) / 5, "valid")
    gs = np.interp(np.arange(len(x)), np.arange(len(g)) * n + n / 2, g)
    return (x * gs).astype(np.float32)
