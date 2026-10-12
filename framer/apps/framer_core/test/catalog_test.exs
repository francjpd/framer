defmodule FramerCore.CatalogTest do
  @moduledoc """
  The catalog is the contract an agent reads, so it is tested as one: every
  entry must be complete and self-consistent, the JSON forms must agree with
  each other, and the set of catalogued operations must match the operations
  the Python Port worker actually registers. The last assertion is the drift
  guard: a new operation in `framer_worker.py` without a catalog entry fails
  this suite, and so does a catalog entry the worker cannot run.
  """

  use ExUnit.Case, async: true

  alias FramerCore.Catalog

  describe "entries" do
    test "every entry is fully described" do
      for operation <- Catalog.operations() do
        assert operation.name =~ ~r/^[a-z][a-z0-9-]*$/,
               "#{inspect(operation.name)} is not a stable command-line name"

        refute operation.summary == "", "#{operation.name} has no summary"
        refute operation.produces == "", "#{operation.name} does not say what it produces"
        refute String.trim(operation.description) == "", "#{operation.name} has no description"
        assert operation.args != [], "#{operation.name} takes no arguments?"
        assert operation.args != [], "#{operation.name} takes no arguments"

        for arg <- operation.args do
          assert arg.name =~ ~r/^[a-z][a-z0-9_]*$/, "argument names must be plain identifiers"
          refute arg.help == "", "#{operation.name} argument #{arg.name} has no help"
        end

        assert Enum.all?(operation.options, &(&1.help != "")),
               "#{operation.name} has an option without help"

        assert Enum.all?(operation.options, &(&1.flag != "")),
               "#{operation.name} has an option without a flag"
      end
    end

    test "names and flags are unique" do
      names = Catalog.names()
      assert names == Enum.uniq(names)

      for operation <- Catalog.operations() do
        flags = Enum.map(operation.options, & &1.flag)
        assert flags == Enum.uniq(flags), "#{operation.name} repeats an option flag"

        shorts = Enum.reject(operation.options, &is_nil(&1.short))

        assert shorts == Enum.uniq_by(shorts, & &1.short),
               "#{operation.name} repeats a short flag"
      end
    end

    test "every required option is described as such and defaults are coherent" do
      for operation <- Catalog.operations() do
        for option <- operation.options do
          assert is_boolean(option.required),
                 "#{operation.name} #{option.flag} must say if it is required"

          if option.required do
            assert is_nil(option.default),
                   "#{operation.name} #{option.flag} is required, so a default is dead code"
          end

          if option.type == :enum do
            assert option.choices not in [nil, []],
                   "#{operation.name} #{option.flag} needs choices"

            assert option.default in option.choices
          else
            assert is_nil(option.choices), "#{operation.name} #{option.flag} is not an enum"
          end
        end
      end
    end

    test "usage lines are runnable-looking" do
      for operation <- Catalog.operations() do
        assert Catalog.usage(operation) ==
                 "framer #{operation.name} #{Enum.map_join(operation.args, " ", &"<#{&1.name}>")} [options]"
      end
    end
  end

  describe "the catalog agrees with the Port worker" do
    @tag :requires_python
    test "every Port operation is catalogued, and every catalog entry is one" do
      assert Enum.sort(Catalog.port_operations()) == Enum.sort(worker_operations())
    end

    @tag :requires_python
    test "the internal Port operations are not catalogued" do
      internal = Catalog.port_internal_ops()

      for name <- internal do
        refute name in Catalog.names(), "#{name} is plumbing, not an operation to run"

        assert name in worker_operations(),
               "#{name} is declared internal but the worker has no #{name}"
      end
    end
  end

  describe "the JSON catalog" do
    test "list --json documents every catalogued operation" do
      document = Catalog.list_json()
      assert document["name"] == "framer"
      assert document["version"] == Catalog.version()

      assert Enum.map(document["operations"], & &1["name"]) == Catalog.names()
      assert document["operations"] != []
    end

    test "describe --json is the same document as the matching list entry" do
      for operation <- Catalog.operations() do
        assert Catalog.entry_json(operation) ==
                 Catalog.list_json()["operations"]
                 |> Enum.find(&(&1["name"] == operation.name))
      end
    end

    test "an entry carries its arguments, options and defaults" do
      deform = Jason.decode!(Jason.encode!(Catalog.entry_json(entry!("deform"))))

      assert deform["name"] == "deform"
      assert Enum.map(deform["args"], & &1["name"]) == ["input", "output"]
      assert deform["usage"] == "framer deform <input> <output> [options]"
      refute deform["produces"] == ""

      options = deform["options"]
      rig = Enum.find(options, &(&1["name"] == "rig"))
      assert rig["required"]
      assert rig["flag"] == "--rig"
      assert rig["short"] == "-r"
      assert rig["type"] == "path"

      workers = Enum.find(options, &(&1["name"] == "workers"))
      assert workers["flag"] == "--workers"
      assert workers["default"] == nil
    end

    test "JSON encodes cleanly" do
      assert {:ok, _} = Jason.decode(Jason.encode!(Catalog.list_json()))
    end
  end

  describe "text rendering" do
    test "list names every operation and how to invoke it" do
      rendered = Catalog.render_list()

      for operation <- Catalog.operations() do
        assert rendered =~ operation.name
        assert rendered =~ Catalog.usage(operation)
      end
    end

    test "describe shows the contract of one operation" do
      rendered = Catalog.render_entry(entry!("loop"))

      assert rendered =~ "loop"
      assert rendered =~ "framer loop <input> <output> [options]"
      assert rendered =~ "--method"
      assert rendered =~ "<input>"
      assert rendered =~ "<output>"
    end
  end

  defp entry!(name), do: Catalog.get(name) || flunk("no catalog entry for #{name}")

  # Reads the operations the Python worker registers, straight from the worker
  # module, so the catalog cannot drift from what the Port can actually run.
  defp worker_operations do
    worker = Application.get_env(:framer_core, :python_worker)
    root = worker |> to_string() |> Path.dirname()

    script = """
    import sys
    sys.path.insert(0, #{inspect(root)})
    import framer_worker
    print(",".join(sorted(framer_worker._OPERATIONS)))
    """

    {output, 0} = System.cmd(FramerCore.PortWorker.python_executable(), ["-c", script])

    output
    |> String.trim()
    |> String.split(",", trim: true)
  end
end
