import Config

config :mini_agent,
  llm_module: MiniAgent.MockLLM,
  workspace: System.tmp_dir!()

config :mini_agent, MiniAgentWeb.Endpoint, server: true
