import Config

config :mini_agent,
  llm_module: MiniAgent.MockLLM,
  workspace: System.tmp_dir!()
