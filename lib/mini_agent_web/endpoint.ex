defmodule MiniAgentWeb.Endpoint do
  @moduledoc "Phoenix Endpoint. Serves the LiveView UI on port 4000."

  use Phoenix.Endpoint, otp_app: :mini_agent

  @session_options [
    store: :cookie,
    key: "_mini_agent_key",
    signing_salt: "miniagnt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: {MiniAgentWeb.Endpoint, :session_options, []}]]
  )

  plug(Plug.Static,
    at: "/",
    from: :mini_agent,
    gzip: false,
    only: ~w(assets fonts images favicon.ico robots.txt)
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(MiniAgentWeb.Router)

  @doc "Returns session cookie options. Used by the LiveView socket connect_info."
  @spec session_options() :: keyword()
  def session_options, do: @session_options
end
