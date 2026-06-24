import Config

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
