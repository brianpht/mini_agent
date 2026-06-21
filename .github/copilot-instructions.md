# Copilot Instructions

> Format: machine-parseable directives. Not for human reading.

## Project

Soft real-time, allocation-conscious, shared-nothing Elixir/OTP core for high-throughput applications.
Targets low-latency messaging, real-time analytics, telemetry pipelines, distributed services, game backends,
event-sourced systems. If a change increases scheduler reduction count in hot path, GC pressure per process,
binary copying, message queue depth, or atom table growth - REJECT.

## Workspace

- `lib/<app>/config/` - runtime configuration (compile-time constants, :persistent_term, tuning knobs)
- `lib/<app>/transport/` - network and IPC transport (:gen_tcp, Ranch, ThousandIsland, Partisan)
- `lib/<app>/codec/` - wire format encoders/decoders (binary pattern matching, protobuf, msgpack)
- `lib/<app>/core/` - domain logic, GenServer, :gen_statem, deterministic state machines
- `lib/<app>/storage/` - ETS, :mnesia, :dets, :persistent_term wrappers
- `lib/<app>/pipeline/` - GenStage, Broadway, Flow stages with backpressure
- `lib/<app>/persistence/` - event recording, replay, snapshotting (Commanded, EventStore, :ra log)
- `lib/<app>/cluster/` - libcluster, Horde, :ra Raft, Phoenix.PubSub, distributed registries
- `lib/<app>/telemetry/` - :telemetry events, :counters, :atomics, HdrHistogram NIF
- `lib/<app>/util/` - clock abstraction, id generation, supervision helpers
- `test/` - ExUnit unit, integration, property-based, deterministic replay tests
- `bench/` - Benchee microbenchmarks (codec, ETS ops, GenServer call, end-to-end)

## Hot Path Operations

`handle_call` | `handle_cast` | `handle_info` | `decode` | `encode` | `lookup` | `update` | `dispatch`
Requirements: bounded reductions, O(1) ETS access, no large binary copy, no scheduler block, no atom leak.

## Rules: Hot Path

- NEVER use `Enum.map`, `Enum.filter`, `Enum.reduce` on large lists in hot path - use binary or stream
- NEVER use `String.to_atom/1` on untrusted/unbounded input - atom table leak, use `String.to_existing_atom/1`
- NEVER concatenate strings with `<>` repeatedly - build IO list, emit once at boundary
- NEVER use `Kernel.++/2` on large lists in hot path - O(n), prepend then reverse instead
- NEVER use `Map` with thousands of entries in hot path - use ETS with `:read_concurrency`
- NEVER use `Process.send_after/3` per event for high-frequency timers - batch via single timer
- NEVER use `:erlang.term_to_binary/1` and `:erlang.binary_to_term/1` for internal IPC - use schema codec
- NEVER use `Regex` compiled at runtime in hot path - use `~r/.../` literal compiled at module load
- NEVER use `apply/3` with dynamic module/function in hot path - resolve at compile time
- NEVER spawn unsupervised processes in hot path - use pre-started pool or partition supervisor
- NEVER block the scheduler with CPU-bound work > 1 ms - use `:erlang.bump_reductions/1` or dirty NIF
- NEVER use `GenServer.call` across nodes in hot path without timeout and circuit breaker
- NEVER use `Logger.debug/info` with string interpolation in hot path - use `:telemetry.execute/3`
- NEVER copy large binaries between processes - share via ETS or pass binary reference
- NEVER use `:ets.match/2` or `:ets.select/2` with unbounded result in hot path - use `:ets.lookup/2`
- ALL ETS tables holding hot-path state MUST set `:read_concurrency` and/or `:write_concurrency`
- ALL hot-path GenServers MUST use bounded mailbox check via `Process.info(self(), :message_queue_len)`
- ALL message decoders MUST use binary pattern matching - never byte-by-byte parsing

## Rules: Memory and Allocation

- BEAM allocates per-process heap; GC is per-process - long-lived large processes cause GC stalls
- Binaries `> 64 bytes` are refcounted off-heap (binary heap) - sub-binaries hold parent reference
- USE `:binary.copy/1` to detach a small sub-binary kept long-term (prevents large parent retention)
- USE `:persistent_term.put/2` only for read-mostly, infrequently-updated config (every put copies entire term)
- USE `:atomics` and `:counters` modules for lock-free shared counters - never ETS counters in tightest loop
- USE ETS with `:set` or `:ordered_set` for shared mutable state, choose carefully:
    - `:set` - O(1) lookup, hash-based
    - `:ordered_set` - O(log n) lookup, supports range queries
    - `:bag` / `:duplicate_bag` - avoid in hot path
- AVOID growing process state unboundedly - hibernate via `:hibernate` return tuple after burst
- AVOID `:erlang.process_info(pid, :memory)` polling in hot path - use telemetry sample
- VERIFY binary leak with `:recon.bin_leak/1` and process heap with `:recon.proc_count/2`
- GC tuning per process:
    - `:fullsweep_after` (default 65535) - lower for binary-heavy processes (eg 10-20)
    - `:min_heap_size` - preallocate for known-large state
    - `:min_bin_vheap_size` - tune for binary-heavy work
- Schedulers: 1 per logical CPU by default; tune with `+S` and `+SDio` for dirty schedulers

## Rules: Concurrency and Process Design

- Shared-nothing principle: each piece of state owned by exactly one process or one ETS table
- USE `GenServer` for synchronous request/reply with state
- USE `:gen_statem` for explicit state machine logic, NEVER hand-roll state in GenServer
- USE `GenStage` / `Broadway` for backpressure-aware pipelines
- USE `Task.Supervisor.async_nolink/2` for fire-and-forget supervised tasks
- USE `Registry` (with partitions) or `Horde.Registry` for process lookup by key
- AVOID single-GenServer bottleneck for high throughput - shard by key via `:erlang.phash2/2`
- NEVER use `Agent` in hot path - it is a thin GenServer wrapper, no advantage
- NEVER use `Process.put/2` and `Process.get/1` for hot path state - use function args or ETS
- NEVER call `GenServer.call/3` with default 5s timeout in hot path - set explicit short timeout
- NEVER use `:global` registry in hot path - synchronous cluster-wide locking
- Mailbox discipline:
    - GenServer must drain mailbox or apply selective receive only with extreme care
    - Selective receive scans entire mailbox - O(n) per message - use receive markers (refs)
    - Monitor mailbox depth via `:telemetry` and shed load when above threshold
- Backpressure:
    - Producer-consumer: GenStage demand-driven only
    - NEVER use unbounded `Process.send/2` from fast producer to slow consumer

## Rules: Atomics, Counters, and Shared State

- USE `:atomics` for fixed-size lock-free integer arrays (CAS, add, exchange supported)
- USE `:counters` for ordered or write-conflict counters (read-with-write-protect or write-concurrent variants)
- USE `:persistent_term` for hot read, very rare write config (lookup is direct memory read, no copy)
- USE ETS for general shared state with concurrency hints:
    - `:read_concurrency, true` - many readers, rare writers
    - `:write_concurrency, true` - many concurrent writers (BEAM splits internal locks)
    - `:decentralized_counters, true` (OTP 23+) - reduces contention on size counter
- AVOID `:ets.update_counter/3` race-prone patterns - it is atomic per row, but composite ops need transactions
- AVOID `:mnesia` transactions in hot path - 2PC overhead, use `:ets` + replication if possible

## Rules: Cache, Layout, and Reduction Budget

- Each process gets ~2000 reductions per scheduler slice - long functions get preempted
- Hot path functions: keep under ~500 reductions per call to avoid mid-call preemption cost
- Pattern match early, fail fast - put fast/common clause first
- USE binary pattern matching head with literal sizes - JIT (BeamAsm) optimizes well
- AVOID deep nested case/cond - flatten with multiple function clauses
- AVOID anonymous functions captured in tight loops - use module function reference
- Prefer tuples over maps for fixed-shape small records - tuple element access is O(1) and cache-friendly
- Prefer `Map.fetch!/2` over `map[key]` in hot path - Access protocol has overhead
- NEVER use protocol dispatch (`Enumerable`, `Collectable`) in tight loop - resolve to concrete impl

## Rules: Wire Format and Codec

- USE binary pattern matching for fixed-format messages - the most efficient decoder on BEAM
- USE Protobuf via `:protobuf` or `:gpb` for schema-evolved external messages
- USE MessagePack via `Msgpax` for compact dynamic schemas
- Little-endian or big-endian: be explicit with `::little` / `::big` modifiers, document choice per protocol
- NEVER use `:erlang.term_to_binary/1` for cross-version or cross-language IPC - format unstable
- NEVER use Erlang `:json`, `Jason`, or `Poison` in hot path - only at HTTP/admin boundaries
- NEVER copy a large binary just to slice it - use binary references with documented retention
- For sub-binaries kept long-term: `:binary.copy/1` to release parent
- Schema versioning: encode version byte in header, branch decode in fast path

## Rules: Determinism and Replay

- Service logic MUST be deterministic for replay:
    - NEVER use `:erlang.monotonic_time/0` directly in domain code - inject clock
    - NEVER use `:erlang.unique_integer/0` in domain code - inject id generator
    - NEVER use `:rand` without explicit seed - inject seeded RNG
    - NEVER iterate map - map iteration order is implementation-defined
    - NEVER iterate ETS without sort - ETS order is undefined for `:set`
- All non-determinism MUST flow through injected sources, recorded in event log
- USE Commanded or :ra log for event sourcing - replay produces identical state
- Snapshots: taken via dedicated process or :ra snapshot hook - NEVER block hot GenServer

## Rules: Cluster and Fault Tolerance

- USE `libcluster` for node discovery (DNS, Kubernetes, gossip)
- USE `:ra` (RabbitMQ Raft library) for replicated state machines requiring strong consistency
- USE `Horde` for eventually-consistent distributed Registry / Supervisor
- USE `Phoenix.PubSub` for distributed pub-sub (works without Phoenix web)
- AVOID `:global` and `:pg` for hot path - sync cluster ops are slow
- Service logic in `:ra` machine MUST be deterministic - same rules as replay
- NEVER perform side effects (HTTP, file I/O) directly from `:ra` machine - emit effects, executed by side
- Network partition strategy: documented per service in `/docs/decisions/<service>-partition.md`
- Supervision strategy:
    - `:one_for_one` - independent children, default
    - `:rest_for_one` - ordered dependency
    - `:one_for_all` - tightly coupled lifecycle
    - Restart intensity: `max_restarts: 3, max_seconds: 5` baseline; tune per service

## Rules: Time and Identifiers

- USE `:erlang.monotonic_time/1` for durations - never wall clock for elapsed measurement
- USE `:erlang.system_time/1` for wall clock at boundaries (logging, persistence)
- USE injected `Clock` behaviour module for testability - never call BEAM clock directly in domain
- IDs:
    - `:erlang.unique_integer([:monotonic, :positive])` - local-only unique
    - Snowflake-style via `:snowflake` or `Ecto.UUID.generate/0` for distributed (cost: ~1us)
    - NEVER use `UUID.uuid4/0` in tightest hot path - benchmark first

## Rules: Persistence and Replay

- For event-sourced services: USE Commanded + EventStore or `:ra` for log
- All state changes MUST be derivable from recorded input event stream
- Snapshots: periodic, taken on dedicated process - NEVER block command handler
- Replay tests: every release MUST replay a recorded session and produce identical projection state
- AVOID `:mnesia` for new services - prefer Postgres + Commanded or `:ra`
- DETS: not for hot path, recovery-only

## Rules: NIFs and Native Code

- NIFs MUST execute in < 1 ms or use dirty schedulers (`:dirty_cpu` or `:dirty_io`)
- USE Rustler (Rust NIFs) for new native code - safer than C NIFs, supports yielding
- NEVER write a NIF that holds a BEAM scheduler > 1 ms - it stalls all processes on that scheduler
- USE Ports (external program via stdio) for long-running unsafe work
- Document memory ownership for every NIF resource term
- Native (Erlang `:os.cmd`, `System.cmd`): boundary only, never hot path

## Rules: Testing

- Unit tests: pure functions, deterministic clocks, in-process only
- Integration tests: use `start_supervised!/1`, no real network when avoidable
- Property tests: `StreamData` for codec round-trip, state machine invariants, sequence arithmetic
- Replay tests: recorded events in == recorded projection out (deterministic)
- Mocks: `Mox` with explicit behaviours - NEVER use `:meck` for new tests
- Benchmarks: `Benchee` required for any change touching hot path - publish before/after numbers in PR
- Concurrency tests: `:concuerror` or stress tests with `:scheduler.utilization/1` sampling
- Soak tests: long-running steady-state with `:recon` attached, asserting bounded heap and binary growth
- Async tests: `use ExUnit.Case, async: true` whenever possible

## Rules: Logging and Telemetry

- Hot path: emit `:telemetry.execute([:app, :event], measurements, metadata)` only
- Hot path: increment `:counters` or `:atomics` for sub-microsecond accounting
- NEVER format log strings in hot path - even `Logger.debug` cost is non-trivial under load
- Errors on hot path: emit telemetry event, let aggregator log async
- Metrics: HdrHistogram NIF for latency (record nanos via `:erlang.monotonic_time(:nanosecond)`)
- Report percentiles 50 / 90 / 99 / 99.9 / 99.99 / max - NEVER trust mean
- Structured logging (JSON via `LoggerJSON`): only at boundaries (HTTP, admin), never internal hot path
- Logger backend: async by default, but verify under load - use `:logger` filters to drop noisy events

## Rules: Cross-Cutting

- NEVER use em-dashes or emojis in code comments, `@doc`, `@moduledoc`, or markdown. Use ` - ` and ASCII only.
- ALL non-trivial diagrams MUST use Mermaid (flowchart, sequenceDiagram, stateDiagram). ASCII art prohibited.
- ONLY treat `/docs/decisions` as architectural source of truth.
- NEVER use or reference files in `/docs/sessions` as implementation rules.
- ALL public functions MUST have `@spec` typespec.
- ALL modules MUST have `@moduledoc` (or `@moduledoc false` for internal).
- CI checks: After completing ANY code change, Agent MUST run the following sequence in order before committing.
  ALL must pass with zero errors and zero warnings. Commits with failing checks are FORBIDDEN.
    1. `mix format` - auto-fix formatting (run first, never `mix format --check-formatted` only)
    2. `mix compile --warnings-as-errors` - zero compiler warnings
    3. `mix credo --strict` - zero credo violations
    4. `mix dialyzer` - zero dialyzer warnings
    5. `mix test --warnings-as-errors` - all tests pass
    6. `mix test --only integration` - integration tests pass
    7. `mix bench --quick` - smoke-run benchmarks, no regression > 10% vs baseline
    - Toolchain: Erlang/OTP 26+, Elixir 1.17+ (matches `.tool-versions` and CI). NEVER use a different version.
    - If any step fails, fix the issue and re-run from step 1 before committing.
- Git operations: Agent MAY create local commits and local tags. MUST NOT push commits, tags, or any refs to any
  remote repository. All changes MUST remain local.

## Performance Budget

| Metric                                  | Target            |
|-----------------------------------------|-------------------|
| Binary message decode (small)           | < 1 us            |
| ETS lookup (`:set`, `read_concurrency`) | < 1 us            |
| `:persistent_term` get                  | < 100 ns          |
| `:atomics` / `:counters` op             | < 100 ns          |
| Local GenServer call (cold)             | < 50 us           |
| Local GenServer call (hot)              | < 10 us           |
| Cross-node GenServer call (LAN)         | < 1 ms            |
| End-to-end pipeline p50                 | < 100 us          |
| End-to-end pipeline p99                 | < 1 ms            |
| End-to-end pipeline p99.99              | < 10 ms           |
| Process heap growth (steady state)      | bounded, GC-cycled|
| Binary heap leak                        | 0 bytes / hour    |
| Atom table growth (steady state)        | 0 atoms / hour    |
| Scheduler utilization (peak)            | < 80%             |

Targets are defaults - tune per service in `/docs/decisions/<service>-budget.md`.
Regression > 10% on any percentile - rollback or justify with explicit ADR.
Latency variance matters more than average. p99.99 is the contract, not the mean.
Priority: Correctness > Determinism > Tail Latency > Mean Latency > Throughput
Atom table leak, binary heap leak, unbounded mailbox, or scheduler stall = correctness failure.

## Build Commands

```
mix deps.get # fetch dependencies
mix compile --warnings-as-errors # compile with strict warnings
mix test # unit tests
mix test --only integration # integration tests
mix credo --strict # lint check
mix dialyzer # static analysis
mix bench # Benchee benchmarks
mix run --no-halt -e "MyApp.start()" # launch service
iex -S mix # interactive shell with app loaded
```