# N-gram table offload design (DRAFT)

Status: DRAFT. This document describes the design that the MLX engine
implements today and that the CUDA engine will follow. Change it in one place
and change both engines.

Audience: the engine teams for the Qwen 3.8 125B-A6B track, on both the MLX
side and the CUDA side.

## 1. Why the table is offloaded

The model keeps a learned n-gram table. The table is addressed by a hash of the
recent token history, not by a token id. It is very large:

| Item | Value |
|---|---|
| Shards | 128 |
| Rows per shard | 2,500,012 |
| Values per row | 160 |
| Quantization (MLX checkpoint) | 4-bit affine, group 32 |
| Bytes per row (MLX checkpoint) | 100 |
| Table size (MLX checkpoint) | 29.80 GiB |

The rest of the model needs about 75 GiB. A 128 GB machine cannot hold both the
model and the table and still leave room for the key-value cache. The table
must therefore stay on the solid-state disk, and only the rows a step needs may
enter memory.

The access pattern makes this cheap. Each token reads 16 rows: 8 heads read the
2-token history and 8 heads read the 3-token history. That is 1.6 kibibytes a
token on the MLX checkpoint. A small cache holds the steady-state working set.

## 2. Contract (runner-neutral)

Any engine that serves this model must satisfy this section. It says nothing
about MLX, about CUDA, or about a file format.

### 2.1 Row identity

A row is identified by ONE integer, the global row id.

* The table holds `shard_count * rows_per_shard` rows.
* Global row id `g` selects shard `g / rows_per_shard` and, inside it, row
  `g % rows_per_shard`.
* Row ids are stable. They are a property of the checkpoint, not of a run.

### 2.2 Hashing a history to row ids

The row ids come from the token history. The procedure is fixed by the
checkpoint and must not be changed:

1. Take the token ids of the sequence, with the previous `ngram_size - 1`
   tokens carried over from the last step.
2. Build `ngram_size` shifted copies of that history. Shift `s` moves each
   token right by `s` positions. A shift must NOT cross an end-of-sequence
   token: where it would, the shifted value is the end-of-sequence id instead.
3. For each n-gram width `n` in 2 ... `ngram_size`, mix the first `n` shifted
   copies: multiply copy `p` by multiplier `p` and combine the products with
   exclusive-or. The arithmetic is 64-bit signed.
4. For head `h` of that width, take the mix modulo the head's vocabulary size,
   then add the head's offset. That is the global row id.
5. Head vocabulary sizes are consecutive primes above `ngram_vocab_size_base`;
   head offsets are their running sum. The multipliers come from a splitmix64
   stream seeded by the configuration seed and the layer index.

The checkpoint also stores the multipliers, the head vocabulary sizes and the
head offsets. An engine may load them, but it must use values it rebuilt from
the configuration, because a dtype conversion over the parameter tree would
destroy the stored copies.

THE MIX IS NON-NEGATIVE BY CONSTRUCTION, SO THE MODULO IS UNAMBIGUOUS. This
is the one place where two correct-looking implementations could disagree, so
state it exactly. Step 3's arithmetic is 64-bit SIGNED, and the multipliers are
built to keep it inside the positive half: each multiplier is an odd value
below `(2^63 - 1) / vocab_size / 2`, so `token * multiplier` cannot overflow
into the sign bit for any token the vocabulary holds. Every product is
therefore non-negative, exclusive-or preserves that, and the mix reaching step
4 is non-negative. Truncating remainder and floor remainder agree on
non-negative dividends, so an engine may use either language's `%` -- but only
because of that bound. An implementation that widened the multipliers, or
carried the mix as 64-bit UNSIGNED and then reinterpreted it, would break the
bound and the two conventions would diverge on about half of all tokens while
every shape and every byte count still matched.

THE IDS FIT IN 32 BITS. Head vocabulary sizes are consecutive primes above
`ngram_vocab_size_base` and head offsets are their running sum, so ids run
`0 ... total_rows - 1`. On the pinned checkpoint there are 16 heads and
`total_rows` is 320,001,446, which is under `2^31`. An engine may carry row ids
as 32-bit signed integers. The margin is about a factor of 6, so a checkpoint
with a larger base would need this re-checked rather than assumed.

`Tests/MLXFastTests/Qwen4ExpNGramHashTests.swift` pins row ids for plain token
sequences, for a sequence carrying an end-of-sequence boundary, and for the
shift-right case, against values computed independently from the MIT mlx-lm
reference's integer arithmetic.

### 2.3 Ceiling semantics

* The ceiling is a number of BYTES, and it bounds the cached rows only. Buffers
  that a single gather needs are not counted.
* The default ceiling is 1 gibibyte (1073741824 bytes).
* An engine must accept the ceiling from a command-line flag and from an
  environment variable. The flag wins.
* A ceiling of zero turns the cache off. Every row is then read from the file.
* A ceiling below the cost of one row behaves as zero.
* The engine reports the ceiling it resolved. It must not silently raise it.

### 2.4 Eviction

* Least recently used, counted per row.
* A row that a step reads moves to the front of the order.
* When the cache is full the row at the back is dropped and its space is
  reused.

### 2.5 Exactness invariant

**The cache must never change a value the model computes.**

This is the load-bearing rule. It holds because the cache stores the RAW
checkpoint bytes of a row, and nothing else. A cached row and a freshly read
row are the same bytes, so the dequantization that follows is the same
arithmetic on the same input.

An engine must pin this with a test that gathers the same row ids under at
least three ceilings — zero, a ceiling small enough to force eviction, and a
ceiling large enough to hold everything — and asserts that the returned rows
and the resulting model values are identical.

An engine must NOT:

* store dequantized rows in a lower precision than the forward pass uses;
* approximate, prefetch speculatively in a way that changes a row, or fall back
  to a nearby row on a miss;
* change the gather order in a way that changes accumulation.

### 2.6 What is out of scope

The design deliberately does NOT include a budget planner, a preflight pass, a
packed row index, or a separate on-disk row file. The plain form above is
enough for the measured working set. Add none of these without evidence that
the plain form cannot work.

## 3. MLX engine

### 3.1 Files

Every file is in the engine fork, `Vendor/mlx-swift-lm`, which this repository
holds as a git submodule.

* `Libraries/MLXLLM/Models/Qwen4ExpNGram.swift` — the hash, the PLE layer, and
  the `Qwen4ExpNGramRowSource` seam. The model declares NO shard parameters.
* `Libraries/MLXLLM/Models/Qwen4ExpNGramTable.swift` — the disk-resident table,
  the row cache, and the `Qwen4ExpNGramRowSourceLoader` entry point.
* `Libraries/MLXRunners/Qwen4ExpRunner.swift` — the runner builds the row
  source from the `qwen4exp.ngramRowSource` resource and installs it on the
  model.

### 3.2 Storage

The shard tensors stay in their safetensors files. The table memory maps each
file that holds a shard and reads rows out of the mapping. Nothing is copied
into resident memory except the rows a gather returns and the rows the cache
holds.

Per shard the table needs three tensors:

| Tensor | Type | Shape |
|---|---|---|
| `...ngram_embedding.shard_N.weight` | U32 | rows x 20 |
| `...ngram_embedding.shard_N.scales` | BF16 | rows x 5 |
| `...ngram_embedding.shard_N.biases` | BF16 | rows x 5 |

The table refuses to start if a shard is missing, if a shape does not match the
declared geometry, or if a dtype is not the one above. It names the shard and
the file in the refusal.

### 3.3 Row layout

One cached row is 100 bytes, laid out as the checkpoint stores it:

```
[ 80 bytes packed 4-bit weights ][ 10 bytes scales ][ 10 bytes biases ]
```

A gather copies the requested rows into three contiguous buffers, wraps them as
arrays without converting them, and dequantizes once for the whole batch with
group size 32 and 4 bits. The result is reshaped to the shape of the requested
ids plus the row width.

### 3.4 Cache

The cache is one fixed arena of row slots plus a least-recently-used order over
those slots. The arena is sized once from the ceiling, so the hot path performs
no allocation and there is no growth path to get wrong.

Controls:

| Control | Name | Default |
|---|---|---|
| Environment variable | `MLXFAST_NGRAM_CACHE_LIMIT` | 1073741824 |
| Flag | `--ngram-cache-limit` | takes priority |

### 3.5 Installing the source

The model refuses to run a forward pass until a row source is installed. The
caller passes the DIRECTORY that holds the n-gram shard files, and the runner
builds the source from it:

```
bench-worker runtime-worker --weights <dir> \
  --resource qwen4exp.ngramRowSource=<shard directory>
```

`fixtures/qwen3_8_125b_a6b_track.json` `ngram_shard_dir` names that directory,
and the measurement script forwards it. Without the resource the runner refuses
at load and names it. The refusal is deliberate. A silent fallback to resident
shards would allocate 29.80 GiB and fail later, far from the cause.

## 4. CUDA engine

The CUDA checkpoint stores the same table as `float8_e4m3fn` rather than 4-bit
affine, so the bytes per row differ. Everything in section 2 still applies: the
row identity, the hashing, the ceiling in bytes, the eviction order and the
exactness invariant do not depend on the row format.

The CUDA engine must state its own row layout in a section beside this one,
with the same table of tensor names, types and shapes, before it ships.
