defmodule FramerWeb.Connections do
  @moduledoc """
  In-memory, host-approved connection contract for the editor's content API.

  The running app is the "main computer": it mints one cryptographically secure
  random pairing id per run and prints it to the host console/log. A remote
  client presents that id to `POST /api/connect`, which creates a *pending*
  request - presenting the id never grants access. Nothing is served until the
  host approves the request on `/connections`. Approval issues an opaque,
  expiring session token; clients send it as a bearer token (`Authorization:
  Bearer <token>`) on the protected content endpoints.

  State lives in memory only - no Ecto - matching the filesystem-first design.
  A fresh pairing id is generated on every application start.
  """

  use GenServer
  require Logger

  @session_ttl 3_600
  @host_ttl 86_400

  @doc "Start the registry (called from the application supervisor)."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The single pairing id minted for this run."
  def pairing_id, do: GenServer.call(__MODULE__, :pairing_id)

  @doc """
  Create a pending connection request for a client that presented `pairing_id`.

  Returns `{:ok, request_id}` or `{:error, :invalid_pairing_id}`.
  """
  def request(pairing_id, meta \\ %{}) do
    GenServer.call(__MODULE__, {:request, pairing_id, meta})
  end

  @doc "Poll a request: `{:pending, id}`, `{:approved, token, expires_at}`, `:denied` or an error."
  def status(request_id), do: GenServer.call(__MODULE__, {:status, request_id})

  @doc "List the pending connection requests, oldest first."
  def pending, do: GenServer.call(__MODULE__, :pending)

  @doc "Approve a pending request, issuing it a session token."
  def approve(request_id), do: GenServer.call(__MODULE__, {:approve, request_id})

  @doc "Deny a pending request."
  def deny(request_id), do: GenServer.call(__MODULE__, {:deny, request_id})

  @doc "Verify a session token: `:ok`, `{:error, :expired}`, `{:error, :unauthorized}` or `{:error, :missing}`."
  def verify(token), do: GenServer.call(__MODULE__, {:verify, token})

  @doc "A long-lived session token for the host operator's own editor browser."
  def host_session, do: GenServer.call(__MODULE__, :host_session)

  @doc "Mint an arbitrary session token (used by the host surface and tests)."
  def issue_session(ttl \\ @session_ttl), do: GenServer.call(__MODULE__, {:issue_session, ttl})

  @doc "PubSub topic the host approval surface subscribes to."
  def topic, do: "connections"

  # --- callbacks ---

  @impl true
  def init(_opts) do
    pairing = token()
    Logger.info("[framer] connection pairing id: #{pairing}")
    IO.puts("\n[framer] connection pairing id: #{pairing}\n")

    {:ok, %{pairing_id: pairing, requests: %{}, sessions: %{}, host_token: nil}}
  end

  @impl true
  def handle_call(:pairing_id, _from, state), do: {:reply, state.pairing_id, state}

  def handle_call({:request, pairing_id, meta}, _from, state) do
    if is_binary(pairing_id) and Plug.Crypto.secure_compare(pairing_id, state.pairing_id) do
      request_id = token()
      request = %{id: request_id, status: :pending, meta: meta, token: nil, expires_at: nil}
      state = put_in(state.requests[request_id], request)
      broadcast()
      {:reply, {:ok, request_id}, state}
    else
      {:reply, {:error, :invalid_pairing_id}, state}
    end
  end

  def handle_call({:status, request_id}, _from, state) do
    case state.requests[request_id] do
      nil ->
        {:reply, {:error, :unknown_request}, state}

      %{status: :pending} ->
        {:reply, {:pending, request_id}, state}

      %{status: :denied} ->
        {:reply, :denied, state}

      %{status: :approved, token: token, expires_at: expires_at} ->
        {:reply, {:approved, token, expires_at}, state}
    end
  end

  def handle_call(:pending, _from, state) do
    list =
      state.requests
      |> Map.values()
      |> Enum.filter(&(&1.status == :pending))
      |> Enum.sort_by(& &1.id)

    {:reply, list, state}
  end

  def handle_call({:approve, request_id}, _from, state) do
    case state.requests[request_id] do
      %{status: :pending} = request ->
        {token, sessions} = mint(state.sessions, @session_ttl)
        expires_at = System.system_time(:second) + @session_ttl
        request = %{request | status: :approved, token: token, expires_at: expires_at}

        state = %{
          state
          | requests: Map.put(state.requests, request_id, request),
            sessions: sessions
        }

        broadcast()
        {:reply, {:ok, token, expires_at}, state}

      nil ->
        {:reply, {:error, :unknown_request}, state}

      _ ->
        {:reply, {:error, :not_pending}, state}
    end
  end

  def handle_call({:deny, request_id}, _from, state) do
    case state.requests[request_id] do
      nil ->
        {:reply, {:error, :unknown_request}, state}

      request ->
        state = put_in(state.requests[request_id], %{request | status: :denied})
        broadcast()
        {:reply, :ok, state}
    end
  end

  def handle_call({:verify, token}, _from, state) when is_binary(token) do
    now = System.system_time(:second)

    case state.sessions[token] do
      nil ->
        {:reply, {:error, :unauthorized}, state}

      %{expires_at: expires_at} when expires_at <= now ->
        {:reply, {:error, :expired}, %{state | sessions: Map.delete(state.sessions, token)}}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:verify, _token}, _from, state), do: {:reply, {:error, :missing}, state}

  def handle_call(:host_session, _from, %{host_token: nil} = state) do
    {token, sessions} = mint(state.sessions, @host_ttl)
    {:reply, token, %{state | host_token: token, sessions: sessions}}
  end

  def handle_call(:host_session, _from, state), do: {:reply, state.host_token, state}

  def handle_call({:issue_session, ttl}, _from, state) do
    {token, sessions} = mint(state.sessions, ttl)
    {:reply, token, %{state | sessions: sessions}}
  end

  defp mint(sessions, ttl) do
    token = token()
    expires_at = System.system_time(:second) + ttl
    {token, Map.put(sessions, token, %{expires_at: expires_at})}
  end

  defp token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp broadcast, do: Phoenix.PubSub.broadcast(FramerWeb.PubSub, topic(), :changed)
end
