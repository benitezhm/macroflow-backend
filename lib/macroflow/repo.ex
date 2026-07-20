defmodule Macroflow.Repo do
  use Ecto.Repo,
    otp_app: :macroflow,
    adapter: Ecto.Adapters.Postgres
end
