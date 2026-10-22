defmodule FramerWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      FramerWebWeb.Telemetry,
      # The editor's durable store: the healing corpus lives here.
      FramerWeb.Repo,
      {DNSCluster, query: Application.get_env(:framer_web, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: FramerWeb.PubSub},
      FramerWeb.Connections,
      # Start a worker by calling: FramerWeb.Worker.start_link(arg)
      # {FramerWeb.Worker, arg},
      # Start to serve requests, typically the last entry
      FramerWebWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FramerWeb.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # The healing corpus's schema is migrated on boot, so the editor's
        # durable store is ready the moment the editor is - the corpus is
        # written from the very first correction, and it must not depend on
        # a manual setup step.
        migrate_store()
        {:ok, pid}

      other ->
        other
    end
  end

  # The store's schema, migrated in place.  The database is a file, so its
  # directory has to exist before the connection opens it.
  defp migrate_store do
    case Application.get_env(:framer_web, FramerWeb.Repo) do
      config when is_list(config) ->
        database = config[:database]

        if is_binary(database) and Path.type(database) == :absolute do
          File.mkdir_p!(Path.dirname(database))
        end

      _ ->
        :ok
    end

    Ecto.Migrator.run(FramerWeb.Repo, :up, all: true)
  rescue
    error ->
      Logger.error("could not migrate the editor's store: #{Exception.message(error)}")
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FramerWebWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
