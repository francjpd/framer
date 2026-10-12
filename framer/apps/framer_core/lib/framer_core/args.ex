defmodule FramerCore.Args do
  @moduledoc """
  Command-line parsing driven entirely by a `FramerCore.Catalog` entry.

  Nothing here knows about a particular operation: it reads the argument list
  and the option table from the catalog, coerces each value to the declared
  type and applies the declared defaults. That is what keeps the invocation
  contract identical to what `framer describe` and `framer list --json` publish.

  The result separates the positional arguments (`%{"input" => "in.mp4"}`) from
  the options (`%{"tolerance" => 30}`). Options whose declared default is `nil`
  are absent from the result rather than present as `nil`, so the map means
  "what this invocation asks the worker for".
  """

  alias FramerCore.Catalog

  @type parsed :: %{positional: %{String.t() => String.t()}, options: %{String.t() => term()}}

  @boolean_literals %{
    "true" => true,
    "1" => true,
    "yes" => true,
    "on" => true,
    "false" => false,
    "0" => false,
    "no" => false,
    "off" => false
  }

  @doc """
  Parse `argv` against `operation`, filling in every catalog default and
  rejecting anything the catalog does not describe.
  """
  @spec parse(Catalog.operation(), [String.t()]) :: {:ok, parsed()} | {:error, String.t()}
  def parse(%{} = operation, argv) do
    with {:ok, positional_values, given} <- scan(operation, argv),
         {:ok, positional} <- bind_positional(operation, positional_values),
         {:ok, options} <- coerce(operation, given) do
      {:ok, %{positional: positional, options: options}}
    end
  end

  # --- token scanning ---

  defp scan(%{} = operation, argv) do
    do_scan(operation, lookup(operation), argv, [], [])
  end

  defp do_scan(_operation, _lookup, [], positional, given) do
    {:ok, Enum.reverse(positional), Enum.reverse(given)}
  end

  defp do_scan(%{} = operation, lookup, [token | rest], positional, given) do
    case flag_token(lookup, token) do
      {:flag, %{} = option, inline} ->
        case value_for(option, inline, rest) do
          {:ok, value, rest} ->
            do_scan(operation, lookup, rest, positional, [{option.name, value} | given])

          {:error, message} ->
            {:error, "#{operation.name}: #{message}"}
        end

      :unknown ->
        {:error, "#{operation.name}: unknown option #{inspect(token)}#{suggest(token, lookup)}"}

      :not_a_flag ->
        do_scan(operation, lookup, rest, [token | positional], given)
    end
  end

  # A token is a flag only when it starts with "-" and is not exactly "-".
  defp option?(token), do: String.starts_with?(token, "-") and token != "-"

  defp flag_token(lookup, token) do
    if option?(token) do
      {flag, inline} =
        case String.split(token, "=", parts: 2) do
          [flag, value] -> {flag, value}
          [flag] -> {flag, nil}
        end

      case Map.fetch(lookup, flag) do
        {:ok, option} -> {:flag, option, inline}
        :error -> :unknown
      end
    else
      :not_a_flag
    end
  end

  # Booleans accept a literal only when one follows: `--refine` alone is true,
  # `--auto-ranges false` is false.
  defp value_for(%{type: :boolean, flag: flag}, inline, rest) do
    cond do
      not is_nil(inline) ->
        parse_bool(flag, inline, rest)

      match?([next | _] when is_binary(next), rest) and boolean_literal?(hd(rest)) ->
        {:ok, Map.fetch!(@boolean_literals, hd(rest)), tl(rest)}

      true ->
        {:ok, true, rest}
    end
  end

  defp value_for(%{flag: flag, arg: arg}, nil, [next | rest]) when is_binary(next) do
    if option?(next) do
      {:error, "#{flag}: missing value, expected <#{arg}>"}
    else
      {:ok, next, rest}
    end
  end

  defp value_for(%{flag: flag, arg: arg}, nil, []) do
    {:error, "#{flag}: missing value, expected <#{arg}>"}
  end

  defp value_for(_option, inline, rest), do: {:ok, inline, rest}

  # Positional tokens are matched to the catalog's argument names in order.
  defp bind_positional(%{} = operation, positional) do
    expected = Enum.map(operation.args, & &1.name)

    cond do
      length(positional) > length(expected) ->
        extra = Enum.drop(positional, length(expected)) |> Enum.map_join(" ", &inspect/1)

        {:error, "#{operation.name}: unexpected #{extra}, #{usage_hint(operation)}"}

      length(positional) < length(expected) ->
        missing = expected |> Enum.drop(length(positional)) |> Enum.map_join(" ", &"<#{&1}>")

        {:error, "#{operation.name}: missing #{missing}, #{usage_hint(operation)}"}

      true ->
        {:ok, Map.new(Enum.zip(expected, positional))}
    end
  end

  # --- value coercion ---

  defp coerce(%{} = operation, given) do
    defaults = defaults(operation)
    given = Map.new(given)

    with :ok <- require_mandatory(operation, given, defaults) do
      Enum.reduce_while(given, {:ok, defaults}, fn {name, value}, {:ok, acc} ->
        option = find_option(operation, name)

        case convert(option, value) do
          {:ok, converted} ->
            {:cont, {:ok, Map.put(acc, name, converted)}}

          {:error, message} ->
            {:halt, {:error, "#{operation.name}: #{option.flag}: #{message}"}}
        end
      end)
    end
  end

  defp convert(%{type: :boolean}, value), do: {:ok, value}
  defp convert(%{type: :string}, value), do: {:ok, value}
  defp convert(%{type: :color}, value), do: {:ok, value}
  defp convert(%{type: :path}, value), do: {:ok, value}

  defp convert(%{type: :integer}, value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "expects an integer, got #{inspect(value)}"}
    end
  end

  defp convert(%{type: :float}, value) do
    case Float.parse(value) do
      {float, ""} -> {:ok, float}
      _ -> {:error, "expects a number, got #{inspect(value)}"}
    end
  end

  defp convert(%{type: :enum, choices: choices}, value) do
    if value in choices do
      {:ok, value}
    else
      {:error, "expects one of #{Enum.join(choices, ", ")} (got #{inspect(value)})"}
    end
  end

  defp require_mandatory(%{} = operation, given, defaults) do
    given_names = Map.keys(given) ++ Map.keys(defaults)

    case Enum.find(operation.options, fn option ->
           option.required and option.name not in given_names
         end) do
      nil -> :ok
      option -> {:error, "#{operation.name}: missing required option #{option.flag}"}
    end
  end

  # --- catalog tables ---

  defp lookup(%{} = operation) do
    shorts =
      operation.options
      |> Enum.reject(&is_nil(&1.short))
      |> Map.new(fn option -> {option.short, option} end)

    Map.new(operation.options, fn option -> {option.flag, option} end)
    |> Map.merge(shorts)
  end

  # A nil default means "not asked for": it is left out of the options map.
  defp defaults(%{} = operation) do
    operation.options
    |> Enum.reject(&is_nil(&1.default))
    |> Map.new(fn option -> {option.name, option.default} end)
  end

  defp find_option(%{} = operation, name) when is_binary(name) do
    Enum.find(operation.options, &(&1.name == name))
  end

  # --- helpers ---

  defp boolean_literal?(token), do: Map.has_key?(@boolean_literals, token)

  defp parse_bool(flag, value, rest) do
    case Map.get(@boolean_literals, String.downcase(value)) do
      nil -> {:error, "#{flag}: expected true or false, got #{inspect(value)}"}
      bool -> {:ok, bool, rest}
    end
  end

  defp usage_hint(%{} = operation) do
    args = Enum.map_join(operation.args, " ", &"<#{&1.name}>")
    "usage: framer #{operation.name} #{args} [options]"
  end

  defp suggest(token, lookup) do
    best =
      lookup
      |> Map.keys()
      |> Enum.max_by(&String.jaro_distance(&1, token), fn -> "" end)

    if best != "" and String.jaro_distance(best, token) > 0.75 do
      " (did you mean #{best}?)"
    else
      ""
    end
  end
end
