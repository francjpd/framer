defmodule FramerCore.CLI do
  @moduledoc """
  The `framer` command surface, and the module the escript starts.

  Every operation runs through the `FramerCore.Catalog` and the same Python
  Port contract (see `docs/elixir-python-ports.md`); the CLI only resolves what
  the invocation asks for and never touches pixels.

  Usage:

      framer list [--json]
      framer describe <operation> [--json]
      framer <operation> <input> <output> [options]
      framer info <file>
      framer connect --id <pairing id> --server http://host:4000
      framer --version | --help

  Agents are the reason this exists: `framer list` / `framer describe` are the
  machine-discoverable catalog, so nobody has to read prose in a README to find
  out what framer can do. `FramerCore.CLI.main/1` keeps the same entry point it
  always had, so `mix run -e 'FramerCore.CLI.main(["deform", ...])'` and the
  `mix remove_bg` / `mix loop_op` / `mix fps_boost` tasks keep working.

  stdout is the machine contract: `list --json` / `describe --json` print JSON,
  a successful operation prints its output path, and everything else
  (progress, diagnostics, human help) goes to stderr. Failures exit 1.
  """

  alias FramerCore.Catalog
  alias FramerCore.JobRunner

  @doc """
  Run one command line and halt with a non-zero status on failure.

  This is the escript entry point (`:main_module`) and the entry point of the
  `mix remove_bg` / `mix loop_op` / `mix fps_boost` tasks. `run/1` does the same
  work and returns the result, and is what the suites call.
  """
  def main(argv) do
    case run(argv) do
      {:ok, _} ->
        :ok

      {:error, message} ->
        IO.puts(:stderr, "❌ #{message}")
        System.halt(1)
    end
  end

  @doc "Run one command line and return its result."
  @spec run([String.t()]) :: {:ok, term()} | {:error, String.t()}
  def run(argv) do
    case argv do
      [] ->
        {:ok, help()}

      ["--help" | _] ->
        {:ok, help()}

      ["-h" | _] ->
        {:ok, help()}

      ["--version" | _] ->
        {:ok, emit(Catalog.version())}

      ["-v" | _] ->
        {:ok, emit(Catalog.version())}

      ["list" | rest] ->
        list(rest)

      ["describe", name | rest] ->
        describe(name, rest)

      ["info", path] ->
        info(path)

      ["connect" | opts] ->
        connect(opts)

      [name | rest] ->
        case Catalog.get(name) do
          nil ->
            {:error,
             "unknown command #{inspect(name)}#{unknown_hint(name)}. " <>
               "Run `framer list` to see the operations."}

          operation ->
            if command_help?(rest) do
              {:ok, emit(Catalog.render_entry(operation))}
            else
              JobRunner.run(operation, rest)
            end
        end
    end
  end

  # --- catalog commands ---

  defp list(argv) do
    with :ok <- only_json?(argv) do
      {:ok, emit(if(argv == [], do: Catalog.render_list(), else: Catalog.list_json()))}
    end
  end

  defp describe(name, argv) do
    case Catalog.get(name) do
      nil ->
        {:error, "unknown operation #{inspect(name)}#{unknown_hint(name)}. Run `framer list`."}

      operation ->
        with :ok <- only_json?(argv) do
          text = Catalog.render_entry(operation)

          {:ok, emit(if(argv == [], do: text, else: Catalog.entry_json(operation)))}
        end
    end
  end

  defp command_help?(argv), do: argv == ["--help"] or argv == ["-h"]

  # --- utility commands ---

  defp info(path) do
    case JobRunner.probe(path) do
      {:ok, info} ->
        {:ok,
         emit("""
         Video Info: #{path}
           Resolution: #{info["width"]}x#{info["height"]}
           FPS: #{info["fps"]}
           Frames: #{info["total_frames"]}
         """)}

      {:error, reason} ->
        {:error, "could not read #{path}: #{JobRunner.brief(reason)}"}
    end
  end

  defp connect(opts) do
    FramerCore.ensure_started!()

    pairing_id = opt(opts, "--id") || opt(opts, "--pairing-id")
    server = opt(opts, "--server", "http://localhost:4000")

    if is_nil(pairing_id) do
      {:error, "connect requires --id <pairing id> (printed by the host at startup)"}
    else
      do_connect(server, pairing_id)
    end
  end

  defp do_connect(server, pairing_id) do
    log("🔌 Requesting a connection to #{server}…")

    with {:ok, request_id} <- connect_request(server, pairing_id),
         {:ok, token} <- connect_poll(server, request_id) do
      emit("""

      ✅ Connection approved. Session token:

      #{token}
      """)

      {:ok, token}
    end
  end

  defp connect_request(server, pairing_id) do
    case Req.post("#{server}/api/connect", json: %{"id" => pairing_id}) do
      {:ok, %{status: 202, body: %{"request_id" => request_id}}} ->
        log("⏳ Pending host approval (request #{request_id}).")
        {:ok, request_id}

      {:ok, %{status: 403}} ->
        {:error, "the host rejected that pairing id"}

      {:ok, %{status: status}} ->
        {:error, "unexpected response (#{status})"}

      {:error, reason} ->
        {:error, "could not reach the host: #{inspect(reason)}"}
    end
  end

  defp connect_poll(server, request_id), do: connect_poll(server, request_id, 600)

  defp connect_poll(_server, _request_id, attempts) when attempts <= 0 do
    {:error, "timed out waiting for host approval"}
  end

  defp connect_poll(server, request_id, attempts) do
    case Req.get("#{server}/api/connect/#{request_id}") do
      {:ok, %{status: 202}} ->
        Process.sleep(1_000)
        connect_poll(server, request_id, attempts - 1)

      {:ok, %{status: 200, body: %{"token" => token}}} ->
        {:ok, token}

      {:ok, %{status: 403}} ->
        {:error, "the host denied the connection request"}

      {:ok, %{status: status}} ->
        {:error, "unexpected response (#{status})"}

      {:error, reason} ->
        {:error, "could not reach the host: #{inspect(reason)}"}
    end
  end

  # --- helpers ---

  defp only_json?([]), do: :ok
  defp only_json?(["--json"]), do: :ok

  defp only_json?(argv) do
    {:error, "unknown argument(s) #{Enum.map_join(argv, " ", &inspect/1)}; expected --json"}
  end

  defp unknown_hint(name) do
    case closest(name) do
      nil -> ""
      near -> " (did you mean #{near}?)"
    end
  end

  defp closest(name) do
    Catalog.names()
    |> Enum.max_by(&String.jaro_distance(&1, name), fn -> nil end)
    |> then(fn near ->
      if near && String.jaro_distance(near, name) > 0.75, do: near, else: nil
    end)
  end

  defp opt(opts, flag, default \\ nil) do
    case Enum.find_index(opts, &(&1 == flag)) do
      nil -> default
      index -> Enum.at(opts, index + 1, default)
    end
  end

  defp emit(%{} = document), do: IO.puts(Jason.encode!(document, pretty: true))
  defp emit(text) when is_binary(text), do: IO.puts(text)

  defp log(message), do: IO.puts(:stderr, message)

  defp help do
    operations =
      Enum.map_join(Catalog.operations(), "\n", fn op -> "    #{op.name}    #{op.summary}" end)

    log("""
    framer #{Catalog.version()} - #{length(Catalog.operations())} operations over the FramerCore orchestrator

    Usage:
      framer list [--json]                  every operation and its contract
      framer describe <operation> [--json]  one operation's full contract
      framer <operation> <input> <output> [options]
      framer <operation> --help             one operation's contract
      framer info <file>                   resolution, FPS and frame count
      framer connect --id <pairing id> [--server http://host:4000]
      framer --version | --help

    Operations:
    #{operations}

    `framer list --json` and `framer describe <operation> --json` emit the same
    catalog as JSON, so an agent can enumerate what framer does without reading
    any prose. A successful operation prints its output path on stdout and its
    progress on stderr.
    """)
  end
end
