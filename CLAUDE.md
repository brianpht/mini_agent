# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## LLM Behavioral Contract

This section overrides generic LLM behavior. These rules are mandatory.s

Before modifying any code:

1. Identify whether the change touches hot-path code.
2. Identify affected modules and list them explicitly.
3. Inspect surrounding modules before proposing changes.
4. Confirm the change respects:
   - Hot path rules
   - Concurrency rules
   - Telemetry/logging rules
   - Determinism rules
5. Prefer minimal, localized changes.
6. Prefer extension over modification.
7. If any assumption is required, state it explicitly.
8. If uncertain, ask for clarification instead of guessing.

After generating code:

1. Re-check typespec correctness.
2. Re-check dialyzer compatibility.
3. Re-check for hot-path violations.
4. Ensure CI steps would pass.
5. Ensure no forbidden patterns are introduced.

Never:
- Introduce architectural drift.
- Modify unrelated modules.
- Add blocking calls in hot path.
- Bypass telemetry boundary.

## Build, test, and lint commands

```bash
mix deps.get                         # install dependencies
mix compile --warnings-as-errors     # strict compile
mix format                           # auto-format all files
mix credo --strict                   # lint
mix dialyzer                         # static analysis
mix test                             # all tests (offline, no API key needed)
mix test test/mini_agent_test.exs    # single test file
mix escript.build                    # build CLI binary
MIX_ENV=dev iex -S mix               # interactive shell (also starts web UI)
```

Tests run entirely offline. `config/test.exs` overrides `llm_module` to `MiniAgent.MockLLM` (a Mox double). No API key is ever needed for the test suite.

## Architecture

This is an Elixir/OTP coding agent that drives a **perceive -> act -> observe** loop against a configurable LLM backend. Two interfaces: CLI (escript) and Phoenix LiveView web UI at `localhost:4000`.

### Core loop (`lib/mini_agent.ex`)

The GenServer loop runs `perceive() |> act() |> observe() |> tick() |> maybe_checkpoint() |> loop()` until `DONE:` appears in the LLM response, max iterations, or budget exhaustion.

- **perceive** -- seeds `messages` with the task on iteration 0; thereafter runs `Memory.maybe_compress/2`.
- **act** -- calls the configured LLM module (via `Application.fetch_env!(:mini_agent, :llm_module)`). Streaming uses `Retry.with_retry_stream/2` (connect-only retry via `:atomics` flag); non-streaming uses `Retry.with_retry/3`.
- **observe** -- dispatches tool calls through `Permission.check/3` then `Tools.execute/3`, appends tool results + optional iteration nudge to messages. If no tool calls, checks for `DONE:`.
- **tick** -- increments `iterations`.
- **maybe_checkpoint** -- saves state to `.mini_agent/checkpoints/<session_id>.json` when `autosave: true`.

From iteration 2 onwards, a nudge is appended to tool results urging the LLM to finish if it has enough information.

### LLM backend (`lib/mini_agent/llm/`)

`Behaviour` defines the `@callback` contract (`chat/2`, `chat_stream/3`, `extract_text/1`, `extract_tool_calls/1`, `usage/1`). Two implementations: `Anthropic` (Claude API) and `DeepSeek` (OpenAI-compatible). `Retry` wraps calls with exponential backoff (1s, 2s, 4s) for transient errors (429, 503, timeouts).

SSE streaming is implemented with pure binary pattern matching parsers (`AnthropicStreamParser`, `DeepSeekStreamParser`). Both convert their accumulated state to the same Anthropic-like response map via `to_response/1`, so the agent loop processes streamed and non-streamed responses identically.

### Telemetry and broadcasting

- **`MiniAgent.Telemetry`** -- the single module allowed to write log output to `IO.puts`. Handles `[:mini_agent, :tool, :executed]`, `:budget, :exceeded`, `:memory, :compressed`, `:iteration, :start`.
- **`MiniAgent.AgentBroadcaster`** -- bridges telemetry events to `Phoenix.PubSub` on `"agent:<session_id>"` topics. The LiveView subscribes to its session topic and renders events as an activity feed + streaming output.
- **`MiniAgent.Permission.ask_user_async/2`** is the only intentional non-telemetry console I/O (reads stdin in `:ask` mode).

### Tool execution and Context propagation

`Tools.execute/3` accepts a `%Context{mode, workspace, session_id}` struct that is threaded through every tool call. This means FileTool and ShellTool never read `Application.get_env` in a hot path -- the workspace is passed down from the agent boundary. Sub-agents inherit the calling agent's context.

The `delegate` tool calls `Orchestrator.run/2` directly. It is excluded from `Tools.safe_definitions/0` (used by sub-agents) to prevent recursive fan-out.

### Orchestrator and SubAgent (`lib/mini_agent/orchestrator.ex`, `lib/mini_agent/sub_agent.ex`)

3-phase pattern: **plan** (LLM breaks task into 2-4 sub-tasks) -> **parallel fan-out** (each sub-task runs in `Task.Supervisor.async_nolink`) -> **synthesize** (LLM combines results).

`SubAgent.run/2` is a pure function (no GenServer) with its own message history and token budget (`@sub_budget` 25_000). Sub-agent budgets are shared-nothing -- total spend for a parallel run = plan + synthesize + sum of all sub-agent budgets, which can exceed the main agent's `token_budget`.

`:ask` mode is automatically downgraded to `:readonly` in the orchestrator because concurrent Tasks cannot safely share a single stdin file descriptor.

### Checkpoint (`lib/mini_agent/checkpoint.ex`)

State is persisted as JSON in `.mini_agent/checkpoints/<session_id>.json`. Transient fields (`stream_callback`, `tool_calls`, `last`) are excluded and reset on resume. Messages are normalized to string-keyed maps for JSON round-trip. An append-only `.history` file tracks save timestamps.

### Config: compile-time vs runtime

All config keys in `config/config.exs` are resolved at compile time via `Application.compile_env!/2` **except** `:workspace`, which is read at runtime via `Application.get_env/3` so the `--workspace` CLI flag can override it without recompiling.

### Testing pattern

`test/test_helper.exs` defines `Mox.defmock(MiniAgent.MockLLM, for: MiniAgent.LLM.Behaviour)`. Tests use `Mox` to set expectations on the mock LLM. Integration tests (`mini_agent_test.exs`) use `start_supervised!` for the agent GenServer. All non-determinism (LLM, clock, workspace) is injectable so core logic is fully testable offline.

## Code conventions

From `.github/copilot-instructions.md` -- these rules apply to all code in this repository.

### CI checks (MUST pass in order before committing)

```
1. mix format
2. mix compile --warnings-as-errors
3. mix credo --strict
4. mix dialyzer
5. mix test --warnings-as-errors
```

If any step fails, fix and re-run from step 1. Toolchain: Erlang/OTP 26+, Elixir 1.18+.

### Hot path rules

The following patterns are **forbidden** in hot-path code (`handle_call`, `handle_cast`, `handle_info`, `Tools.execute/3`, message decoders):

- `String.to_atom/1` on untrusted/unbounded input -- use `String.to_existing_atom/1`
- `Regex` compiled at runtime -- use `~r/.../` literal compiled at module load
- `apply/3` with dynamic module/function -- resolve at compile time
- Repeated string concatenation with `<>` -- build IO list, emit once at boundary
- `Kernel.++/2` on large lists -- prepend then reverse
- Blocking the scheduler with CPU-bound work > 1 ms
- `Logger.debug/info` with string interpolation in hot path -- use `:telemetry.execute/3`
- Spawning unsupervised processes -- use pre-started pool or `Task.Supervisor`
- Binary pattern matching preferred for all message decoding -- never byte-by-byte parsing

### Logging and telemetry

- Hot path: emit `:telemetry.execute([:app, :event], measurements, metadata)` only
- Never format log strings in hot path -- even `Logger.debug` cost is non-trivial
- `IO.puts` for log output is centralized in `MiniAgent.Telemetry`; new modules must not call `IO.puts` directly
- Structured logging only at boundaries (HTTP, admin), never internal hot path

### Concurrency and process design

- Shared-nothing: each piece of state owned by exactly one process or one ETS table
- Use `Task.Supervisor.async_nolink/2` for fire-and-forget supervised tasks
- Avoid single-GenServer bottleneck -- shard by key via `:erlang.phash2/2`
- GenServer mailbox: drain or use selective receive with refs, monitor depth via telemetry
- Never use `Agent` in hot path (thin GenServer wrapper, no advantage)
- Never call `GenServer.call/3` with default 5s timeout in hot path -- set explicit short timeout

### Memory and allocation

- Binaries > 64 bytes are refcounted off-heap -- use `:binary.copy/1` to detach small sub-binaries kept long-term
- Avoid growing process state unboundedly -- hibernate via `:hibernate` return tuple after burst
- `:persistent_term.put/2` only for read-mostly, infrequently-updated config (every put copies entire term)

### Determinism and testing

- Service logic must be deterministic: inject clock, id generator, and RNG -- never call BEAM clock directly in domain code
- Unit tests: pure functions, deterministic clocks, in-process only
- Mocks: `Mox` with explicit behaviours -- never use `:meck`
- Async tests: `use ExUnit.Case, async: true` whenever possible

### Style

- All public functions must have `@spec` typespecs
- All modules must have `@moduledoc` (or `@moduledoc false` for internal)
- No emojis in code, `@doc`, `@moduledoc`, or markdown -- ASCII only
- Git: local commits and tags only -- never push to remotes