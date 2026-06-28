import Config

# Req HTTP client: use Finch for connection pooling (reuses TLS connections).
config :req, adapter: Req.Finch

config :mini_agent, MiniAgentWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: true,
  check_origin: false,
  secret_key_base:
    System.get_env(
      "SECRET_KEY_BASE",
      "dev-default-not-for-production-64-chars-minimum--1234567890123456789012345678"
    ),
  live_view: [signing_salt: "miniagnt"]

config :mini_agent,
  model: "deepseek-chat",
  max_iterations: 8,
  max_tokens: 2048,
  token_budget: 50_000,
  compress_token_threshold: 8_000,
  workspace: File.cwd!(),
  llm_module: MiniAgent.LLM.DeepSeek,
  shell_whitelist: ~w[ls cat grep find wc head tail echo mix git rg fd bat]

import_config "#{config_env()}.exs"
