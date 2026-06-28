import Config

if config_env() == :prod do
  config :mini_agent, MiniAgentWeb.Endpoint, secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
end
