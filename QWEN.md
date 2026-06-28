# QWEN.md

Project context and development guidance for Qwen Code when working with code in this repository.

## Project Identity

**Mini Agent** is a soft real-time, allocation-conscious Elixir/OTP coding agent that drives a `perceive -> act -> observe` loop against a configurable LLM backend. Two interfaces: CLI (escript) and Phoenix LiveView web UI at `http://localhost:4000`.

- Elixir ~> 1.18 / Erlang/OTP 26+
- Version: 0.8.0
- LLM backends: `MiniAgent.LLM.DeepSeek` (default, OpenAI-compatible) and `MiniAgent.LLM.Anthropic` (Claude API)

## Build, Test, and Lint Commands

```bash
mix deps.get                          # install dependencies
mix compile --warnings-as-errors      # strict compile
mix format                            # auto-format all files
mix credo --strict                    # lint
mix dialyzer                          # static analysis
mix test                              # all tests (offline, no API key needed)
mix test test/mini_agent_test.exs     # single file
mix escript.build                     # build CLI binary
MIX_ENV=dev iex -S mix               # interactive shell (also starts web UI)
```

Tests run entirely offline. `config/test.exs` overrides `llm_module` to `MiniAgent.MockLLM` (a Mox double). No API key is ever needed for the test suite.

**CI pipeline** (run in order, all must pass before committing):

```
mix format && mix compile --warnings-as-errors && mix credo --strict && mix dialyzer && mix test --warnings-as-errors
```

## Architecture

### Core loop (`lib/mini_agent.ex`)

The GenServer runs `perceive() |> act() |> observe() |> tick() |> maybe_checkpoint() |> loop()` until `DONE:` appears in the LLM response, `max_iterations` (8), or budget exhaustion (`token_budget`: 50,000).

- **perceive** -- seeds `messages` with the task on iteration 0; thereafter runs `Memory.maybe_compress/2`
- **act** -- calls the configured LLM module via `Application.fetch_env!(:mini_agent, :llm_module)`. Streaming uses `Retry.with_retry_stream/2` (connect-only retry via `:atomics` flag); non-streaming uses `Retry.with_retry/3` (full retry with exponential backoff: 1s, 2s, 4s)
- **observe** -- dispatches tool calls through `Permission.check/3` then `Tools.execute/3`, appends tool results + optional iteration nudge to messages. If no tool calls, checks for `DONE:`
- **tick** -- increments `iterations`
- **maybe_checkpoint** -- saves state to `.mini_agent/checkpoints/<session_id>.json` when `autosave: true`

From iteration 2 onwards, a nudge is appended to tool results urging the LLM to finish if it has enough information.

### LLM backend (`lib/mini_agent/llm/`)

`Behaviour` defines the `@callback` contract. Two implementations: `Anthropic` and `DeepSeek`. `Retry` wraps calls with exponential backoff for transient errors (429, 503, timeouts).

SSE streaming uses pure binary pattern matching parsers (`AnthropicStreamParser`, `DeepSeekStreamParser`). Both convert their accumulated state to the same Anthropic-like response map via `to_response/1`, so the agent loop processes streamed and non-streamed responses identically.

### Tools (`lib/mini_agent/tools.ex`, `lib/mini_agent/tools/`)

- `read_file` (with offset pagination, 4000 bytes per call)
- `list_dir`
- `write_file` (dangerous)
- `shell` (dangerous, whitelisted commands)
- `delegate` (decomposes into parallel sub-agents via Orchestrator)

`Tools.execute/3` accepts a `%Context{mode, workspace, session_id}` struct threaded through every tool call. FileTool and ShellTool never read `Application.get_env` in a hot path.

The `delegate` tool is excluded from `Tools.safe_definitions/0` (used by sub-agents) to prevent recursive fan-out.

### Orchestrator and SubAgent (`lib/mini_agent/orchestrator.ex`, `lib/mini_agent/sub_agent.ex`)

3-phase pattern: **plan** (LLM breaks task into 2-4 sub-tasks) -> **parallel fan-out** (each sub-task runs in `Task.Supervisor.async_nolink`) -> **synthesize** (LLM combines results).

`SubAgent.run/2` is a pure function (no GenServer) with its own message history and token budget (`@sub_budget` 25,000). Sub-agent budgets are shared-nothing: total spend for a parallel run = plan + synthesize + sum of all sub-agent budgets, which can exceed the main agent's `token_budget`.

`:ask` mode is automatically downgraded to `:readonly` in the orchestrator because concurrent Tasks cannot safely share a single stdin file descriptor.

### Telemetry and logging

`MiniAgent.Telemetry` is the **single module** allowed to write log output to `IO.puts`. Handles `[:mini_agent, :tool, :executed]`, `:budget, :exceeded`, `:memory, :compressed`, `:iteration, :start`, `:orchestrator, :total_spend`.

`MiniAgent.AgentBroadcaster` bridges telemetry events to `Phoenix.PubSub` on `"agent:<session_id>"` topics. The LiveView subscribes to its session topic and renders events as an activity feed + streaming output.

`MiniAgent.Permission.ask_user_async/2` is the only intentional non-telemetry console I/O (reads stdin in `:ask` mode).

### Context propagation

`Tools.execute/3` accepts a `%Context{mode, workspace, session_id}` struct. Sub-agents inherit the calling agent's context. This means tool modules never call `Application.get_env` in hot paths.

### Checkpoint (`lib/mini_agent/checkpoint.ex`)

State is persisted as JSON in `.mini_agent/checkpoints/<session_id>.json`. Transient fields (`stream_callback`, `tool_calls`, `last`) are excluded and reset on resume. Messages are normalized to string-keyed maps for JSON round-trip.

### Config: compile-time vs runtime

All config keys in `config/config.exs` are resolved at compile time via `Application.compile_env!/2` **except** `:workspace`, which is read at runtime via `Application.get_env/3` so the `--workspace` CLI flag can override it without recompiling.

| Key | Default | Description |
|-----|---------|-------------|
| `:model` | `"deepseek-chat"` | LLM model name |
| `:max_iterations` | `8` | Hard cap on perceive-act-observe cycles |
| `:max_tokens` | `2048` | Max tokens per LLM response |
| `:token_budget` | `50_000` | Total token spend cap per agent run |
| `:compress_token_threshold` | `8_000` | Tokens consumed before context compression fires |
| `:workspace` | `File.cwd!()` | Sandbox root (runtime overridable) |
| `:llm_module` | `MiniAgent.LLM.DeepSeek` | LLM implementation module |
| `:shell_whitelist` | `~w[ls cat grep find wc head tail echo mix git rg fd bat]` | Allowed shell commands |
| `:checkpoint_dir` | `".mini_agent/checkpoints"` | Checkpoint storage directory |

### Web UI (`lib/mini_agent_web/`)

Phoenix LiveView at `localhost:4000`. Bandit HTTP adapter + WebSocket. The `AgentLive` module renders a task form, options panel, sessions panel, streaming output, and activity feed.

## Key Source Files

| File | Purpose |
|------|---------|
| `lib/mini_agent.ex` | GenServer main loop |
| `lib/mini_agent/application.ex` | OTP Application: TaskSupervisor + PubSub + Endpoint |
| `lib/mini_agent/agent_broadcaster.ex` | Telemetry -> PubSub bridge |
| `lib/mini_agent/budget.ex` | Token quota - pure struct |
| `lib/mini_agent/checkpoint.ex` | Checkpoint save/load/list/delete |
| `lib/mini_agent/memory.ex` | Context compression |
| `lib/mini_agent/permission.ex` | Permission gate (`:auto` / `:ask` / `:readonly`) |
| `lib/mini_agent/tools.ex` | Tool registry and dispatcher |
| `lib/mini_agent/tools/context.ex` | ToolContext struct |
| `lib/mini_agent/tools/file_tool.ex` | File read/write/list operations |
| `lib/mini_agent/tools/shell_tool.ex` | Whitelisted shell command execution |
| `lib/mini_agent/sub_agent.ex` | Pure-function sub-agent loop |
| `lib/mini_agent/orchestrator.ex` | Multi-agent plan/fan-out/synthesize |
| `lib/mini_agent/telemetry.ex` | Console log output (sole IO.puts location) |
| `lib/mini_agent/cli.ex` | Escript entry point |
| `lib/mini_agent/llm/behaviour.ex` | LLM `@callback` contract |
| `lib/mini_agent/llm/anthropic.ex` | Anthropic API client + streaming |
| `lib/mini_agent/llm/anthropic_stream_parser.ex` | Anthropic SSE parser |
| `lib/mini_agent/llm/deepseek.ex` | DeepSeek API client |
| `lib/mini_agent/llm/deepseek_stream_parser.ex` | DeepSeek SSE parser |
| `lib/mini_agent/llm/retry.ex` | Exponential backoff retry |
| `lib/mini_agent_web/endpoint.ex` | Bandit HTTP + WebSocket |
| `lib/mini_agent_web/router.ex` | Routes `/` -> AgentLive |
| `lib/mini_agent_web/live/agent_live.ex` | LiveView UI |

## Hot Path Rules

These rules apply to `handle_call`, `handle_cast`, `handle_info`, `Tools.execute/3`, and message decoders:

- **NEVER** `String.to_atom/1` on untrusted input -- use `String.to_existing_atom/1`
- **NEVER** compile `Regex` at runtime -- use `~r/.../` literal at module load
- **NEVER** `apply/3` with dynamic module/function -- resolve at compile time
- **NEVER** repeated `<>` concatenation -- build IO list, emit once at boundary
- **NEVER** `Kernel.++/2` on large lists -- prepend then reverse
- **NEVER** block scheduler > 1 ms with CPU-bound work
- **NEVER** `Logger.debug/info` with string interpolation -- use `:telemetry.execute/3`
- **NEVER** spawn unsupervised processes -- use pre-started pool or `Task.Supervisor`
- **ALWAYS** use binary pattern matching for message decoding -- never byte-by-byte
- **NEVER** use `Agent` in hot path (thin GenServer wrapper, no advantage)
- **NEVER** call `GenServer.call/3` with default 5s timeout in hot path -- set explicit short timeout

## Logging and Telemetry

- Hot path: emit `:telemetry.execute([:app, :event], measurements, metadata)` only
- Never format log strings in hot path -- even `Logger.debug` cost is non-trivial
- `IO.puts` for log output is centralized in `MiniAgent.Telemetry`; new modules must not call `IO.puts` directly
- Structured logging only at boundaries (HTTP, admin), never internal hot path

## Concurrency and Process Design

- Shared-nothing: each piece of state owned by exactly one process or one ETS table
- Use `Task.Supervisor.async_nolink/2` for fire-and-forget supervised tasks
- Avoid single-GenServer bottleneck -- shard by key via `:erlang.phash2/2`
- GenServer mailbox: drain or use selective receive with refs, monitor depth via telemetry

## Memory and Allocation

- Binaries > 64 bytes are refcounted off-heap -- use `:binary.copy/1` to detach small sub-binaries kept long-term
- Avoid growing process state unboundedly -- hibernate via `:hibernate` return tuple after burst
- `:persistent_term.put/2` only for read-mostly, infrequently-updated config

## Determinism and Testing

- Service logic must be deterministic: inject clock, id generator, and RNG -- never call BEAM clock directly in domain code
- Unit tests: pure functions, deterministic clocks, in-process only
- Mocks: `Mox` with explicit behaviours -- never use `:meck`
- Async tests: `use ExUnit.Case, async: true` whenever possible
- Test helper defines `Mox.defmock(MiniAgent.MockLLM, for: MiniAgent.LLM.Behaviour)`

## Code Style

- All public functions must have `@spec` typespecs
- All modules must have `@moduledoc` (or `@moduledoc false` for internal)
- No emojis in code, `@doc`, `@moduledoc`, or markdown -- ASCII only
- `.formatter.exs` covers `{mix,.formatter}.exs`, `{config,lib,test}/**/*.{ex,exs}`

## Permission Modes

| Mode | Behaviour |
|------|-----------|
| `:ask` (default) | Prompts stdin for approval before `write_file` or `shell` |
| `:auto` | Approves all tool calls silently |
| `:readonly` | Blocks `write_file` and `shell` entirely |

## Shell Tool Whitelist

```
ls  cat  grep  find  wc  head  tail  echo  mix  git  rg  fd  bat
```

All commands are sandboxed to `:workspace`. Output capped at 4000 bytes.

## Streaming

When streaming is enabled, the agent calls `chat_stream/3` instead of `chat/2`. Text tokens are printed to the terminal as each SSE chunk arrives. Both backends support real-time streaming via dedicated pure-function SSE parsers.

Streaming uses connect-only retry: once the first chunk reaches the caller, errors are not retried to prevent duplicate output.

## Loop Termination

The agent loop terminates when:

| Condition | Message |
|-----------|---------|
| LLM response contains `DONE:` | Output is the full response text |
| `max_iterations` reached | `"Max iterations (N) reached"` |
| Token budget exhausted | `"Budget exceeded. Token: X/Y (Z%)"` |
| LLM returns an error (after retries) | `"LLM error: ..."` |

## Dependencies

| Dep | Version | Purpose |
|-----|---------|---------|
| `req` | ~> 0.5 | HTTP client for LLM API calls |
| `jason` | ~> 1.4 | JSON encoding/decoding |
| `telemetry` | ~> 1.3 | Telemetry events |
| `phoenix` | ~> 1.7 | Web framework |
| `phoenix_live_view` | ~> 1.0 | LiveView for web UI |
| `phoenix_html` | ~> 4.0 | HTML helpers |
| `bandit` | ~> 1.5 | HTTP server |
| `credo` | ~> 1.7 | Linter (dev/test only) |
| `dialyxir` | ~> 1.4 | Static analysis (dev/test only) |
| `mox` | ~> 1.2 | Mock framework (test only) |
| `stream_data` | ~> 1.1 | Property-based testing (test only) |

## Git Policy

- Local commits and tags only -- never push to remotes
- Run full CI sequence before committing
