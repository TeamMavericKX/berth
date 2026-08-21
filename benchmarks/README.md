# Scanner benchmarks

`berth scan` probes the default range 1000-9999 on loopback with a bounded
pool of 20 workers, 500 ms connect timeout, IPv4-then-IPv6 fallback.

## Method

- Machine: x86_64-linux laptop, kernel TCP stack, no tuning.
- Fixture: three listeners open inside the range (47101, 47202, 47303).
- Timing: wall clock around `scanner.scanRange(io, gpa, 1000, 9999, null)`,
  Debug build (unoptimized; release will be faster).

## Results

| Run | Range | Workers | Timeout | Wall time | Open found |
|-----|-------|---------|---------|-----------|------------|
| 1   | 1000-9999 | 20 | 500 ms | 187 ms | 3/3 |

Closed ports dominate the cost: each miss costs one SYN round-trip to the
loopback reject path (~0.2 ms), so 9000 ports / 20 workers ≈ 450 probes per
worker ≈ 90-200 ms. The 500 ms timeout only bites when something blackholes
SYNs (filtered host); healthy loopback scans never wait for it.

## Comparison with portmap

portmap (the Rust prototype this module descends from) used the same shape:
CONNECT_TIMEOUT 500ms, MAX_CONCURRENT 20, IPv4-then-IPv6 probe. Its recorded
full-range numbers were in the same order of magnitude (~150-250 ms on
comparable hardware). The Zig port matches that within noise while dropping
the tokio dependency entirely — the pool here is 20 bare `std.Thread`s and a
shared atomic cursor.

Re-run locally with:

```
zig run src/scan_bench.zig -lc
```
