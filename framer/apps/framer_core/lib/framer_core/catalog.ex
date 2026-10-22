defmodule FramerCore.Catalog do
  @moduledoc """
  The single definition of the operations the `framer` command exposes.

  Every entry is one map with the same shape: the operation's stable name, a
  one-line summary, a longer description, the positional arguments it takes,
  the options it accepts (with types, defaults and help text), what it produces
  and how the frame count is resolved before the job is chunked.

  `FramerCore.CLI` renders `framer list` and `framer describe` from this table
  and `FramerCore.JobRunner` drives the very same entries through the
  orchestrator, so the human help and the machine-readable JSON catalog cannot
  drift apart: there is exactly one place to add or change an operation.

  ## Adding an operation

  Add one entry to `@operations`. The suites then enforce the rest:

    * `FramerCore.CatalogTest` fails when an operation in the Python Port
      worker (`framer_worker.py`'s `_OPERATIONS`) has no catalog entry, when a
      catalog entry has no worker handler, and when a catalogued option is sent
      under a key the worker never reads.
    * `FramerCore.Args` rejects an invocation the entry does not describe.

  ## Machine-readable contract

  `framer list --json` emits `%{"name" => ..., "version" => ...,
  "operations" => [...]}`; `framer describe <operation> --json` emits one
  operation entry. Both come from `entry_json/1` below, so the two forms are
  the same document.
  """

  @type option_type :: :string | :integer | :float | :boolean | :color | :path | :enum

  @type argument :: %{name: String.t(), help: String.t(), required: boolean()}

  @type option :: %{
          name: String.t(),
          flag: String.t(),
          short: String.t() | nil,
          type: option_type(),
          default: term(),
          required: boolean(),
          choices: [String.t()] | nil,
          arg: String.t(),
          help: String.t()
        }

  @type operation :: %{
          name: String.t(),
          label: String.t(),
          summary: String.t(),
          description: String.t(),
          args: [argument()],
          options: [option()],
          produces: String.t(),
          frames: :info | {:rig, String.t()}
        }

  # Port operations that are plumbing rather than agent-facing operations:
  # `info` resolves a media file's frame count and fps, `merge` glues finished
  # chunks into the final output. Both are driven by framer itself, never by an
  # agent listing what it can run.
  @port_internal_ops ~w(info merge patch)

  # One option definition, reused by every operation: sizing the player pool is
  # a property of the orchestrator, not of a single operation.
  @workers_option %{
    name: "workers",
    flag: "--workers",
    short: nil,
    type: :integer,
    default: nil,
    required: false,
    choices: nil,
    arg: "N",
    help: "Parallel players for this job (default: the configured worker count)",
    worker_key: nil
  }

  @operations [
    %{
      name: "remove-bg",
      label: "Background removal",
      summary: "Remove the background from a video, writing an alpha channel",
      description: """
      Keys the background out frame by frame and writes an alpha-capable
      container. The background colour is either given with `--color` or
      detected from the clip; detection can also use motion, or combine both.
      The job is chunked across the player pool, so a long clip keys in
      parallel, then the chunks are concatenated into the output.
      """,
      args: [
        %{name: "input", help: "video to key, for example in.mp4", required: true},
        %{name: "output", help: "destination, .webm or .mov to keep the alpha", required: true}
      ],
      options: [
        %{
          name: "color",
          flag: "--color",
          short: "-c",
          type: :color,
          default: nil,
          required: false,
          choices: nil,
          arg: "COLOR",
          help: "Background colour as #RRGGBB or B,G,R (default: detected from the clip)"
        },
        %{
          name: "tolerance",
          flag: "--tolerance",
          short: "-t",
          type: :integer,
          default: 30,
          required: false,
          choices: nil,
          arg: "N",
          help: "Colour tolerance, 0-255"
        },
        %{
          name: "edges",
          flag: "--edges",
          short: "-e",
          type: :integer,
          default: 5,
          required: false,
          choices: nil,
          arg: "N",
          help: "Soft edge width in pixels"
        },
        %{
          name: "auto_ranges",
          flag: "--auto-ranges",
          short: nil,
          type: :boolean,
          default: true,
          required: false,
          choices: nil,
          arg: "[BOOL]",
          help: "Generate a spread of colour ranges around the background colour"
        },
        %{
          name: "num_ranges",
          flag: "--num-ranges",
          short: "-n",
          type: :integer,
          default: 5,
          required: false,
          choices: nil,
          arg: "N",
          help: "Number of generated colour ranges"
        },
        %{
          name: "method",
          flag: "--method",
          short: "-m",
          type: :enum,
          default: "color",
          required: false,
          choices: ~w(color motion combined),
          arg: "METHOD",
          help: "Background detection method"
        },
        %{
          name: "motion_frames",
          flag: "--motion-frames",
          short: "-mf",
          type: :integer,
          default: 30,
          required: false,
          choices: nil,
          arg: "N",
          help: "Frames sampled for motion detection"
        },
        %{
          name: "edge_cleanup",
          flag: "--edge-cleanup",
          short: "-ec",
          type: :integer,
          default: 3,
          required: false,
          choices: nil,
          arg: "N",
          help: "Colour-spill cleanup iterations on the key edge"
        },
        %{
          name: "adaptive_bg",
          flag: "--adaptive-bg",
          short: nil,
          type: :boolean,
          default: false,
          required: false,
          choices: nil,
          arg: "[BOOL]",
          help: "Detect the background per frame instead of once"
        },
        %{
          name: "refine",
          flag: "--refine",
          short: "-r",
          type: :boolean,
          default: false,
          required: false,
          choices: nil,
          arg: "[BOOL]",
          help: "Run a mask refinement pass"
        },
        %{
          name: "refine_tolerance",
          flag: "--refine-tolerance",
          short: "-rt",
          type: :integer,
          default: 45,
          required: false,
          choices: nil,
          arg: "N",
          help: "Refinement tolerance, 0-255"
        },
        %{
          name: "refine_block_size",
          flag: "--refine-block-size",
          short: "-rb",
          type: :integer,
          default: 32,
          required: false,
          choices: nil,
          arg: "N",
          help: "Refinement block size in pixels"
        },
        %{
          name: "force_cpu",
          flag: "--force-cpu",
          short: nil,
          type: :boolean,
          default: false,
          required: false,
          choices: nil,
          arg: "[BOOL]",
          help: "Disable GPU acceleration"
        },
        @workers_option
      ],
      produces: "an alpha-channel video (.webm or .mov) with the background keyed out",
      frames: :info
    },
    %{
      name: "fps-boost",
      label: "Frame-rate boost",
      summary: "Interpolate a video to a higher frame rate",
      description: """
      Re-times a frame range to `--to` frames per second with FFmpeg's
      `minterpolate` (falling back to the `fps` filter when the build lacks
      it). Each chunk is interpolated independently and chunks never overlap a
      boundary frame, so the concatenation matches the single-pass baseline.
      """,
      args: [
        %{name: "input", help: "video to interpolate", required: true},
        %{name: "output", help: "destination video", required: true}
      ],
      options: [
        %{
          name: "target_fps",
          flag: "--to",
          short: nil,
          type: :integer,
          default: 60,
          required: false,
          choices: nil,
          arg: "FPS",
          help: "Target frame rate"
        },
        @workers_option
      ],
      produces: "a video resampled to the target frame rate",
      frames: :info
    },
    %{
      name: "loop",
      label: "Seamless loop",
      summary: "Create a seamless infinite loop",
      description: """
      Builds a clip whose last frame leads back into its first. `--method auto`
      analyses the clip and picks a method; the explicit methods cover bouncing
      motion (pingpong), complex motion (morph), periodic motion (periodic)
      and the rest of the documented cases. Looping reads the whole file, so
      the orchestrator runs it as a single chunk.
      """,
      args: [
        %{name: "input", help: "video to loop", required: true},
        %{name: "output", help: "destination video", required: true}
      ],
      options: [
        %{
          name: "method",
          flag: "--method",
          short: nil,
          type: :enum,
          default: "auto",
          required: false,
          choices: ~w(auto pingpong morph periodic hold fade blend reverse speedramp),
          arg: "METHOD",
          help: "Looping method (auto analyses the clip and picks one)"
        },
        %{
          name: "fade_color",
          flag: "--fade-color",
          short: nil,
          type: :color,
          default: "transparent",
          required: false,
          choices: nil,
          arg: "COLOR",
          help: "Fade colour: transparent, #RRGGBB or B,G,R"
        },
        %{
          name: "fade_frames",
          flag: "--fade-frames",
          short: nil,
          type: :integer,
          default: 10,
          required: false,
          choices: nil,
          arg: "N",
          help: "Frames used by the fade transition"
        },
        %{
          name: "fade_type",
          flag: "--fade-type",
          short: nil,
          type: :enum,
          default: "both",
          required: false,
          choices: ~w(in out both),
          arg: "TYPE",
          help: "Which ends fade"
        },
        %{
          name: "morph_steps",
          flag: "--morph-steps",
          short: nil,
          type: :integer,
          default: 10,
          required: false,
          choices: nil,
          arg: "N",
          help: "Optical-flow warp steps for morph"
        },
        %{
          name: "cycle_frames",
          flag: "--cycle-frames",
          short: nil,
          type: :integer,
          default: nil,
          required: false,
          choices: nil,
          arg: "N",
          help: "Manual cycle length for periodic (default: detected)"
        },
        %{
          name: "hold_frames",
          flag: "--hold-frames",
          short: nil,
          type: :integer,
          default: 2,
          required: false,
          choices: nil,
          arg: "N",
          help: "Freeze frames used by hold"
        },
        %{
          name: "blend_mode",
          flag: "--blend-mode",
          short: nil,
          type: :enum,
          default: "add",
          required: false,
          choices: ~w(add multiply screen overlay),
          arg: "MODE",
          help: "Blend mode for the blend method"
        },
        %{
          name: "ramp_factor",
          flag: "--ramp-factor",
          short: nil,
          type: :float,
          default: 1.0,
          required: false,
          choices: nil,
          arg: "FACTOR",
          help: "Speed adjustment for speedramp, 0.8-1.2"
        },
        %{
          name: "analyze_only",
          flag: "--analyze-only",
          short: nil,
          type: :boolean,
          default: false,
          required: false,
          choices: nil,
          arg: "[BOOL]",
          help: "Analyse the clip and report the detected loop point without writing the output"
        },
        %{
          name: "until",
          flag: "--until",
          short: nil,
          type: :float,
          default: nil,
          required: false,
          choices: nil,
          arg: "SECONDS",
          help: "Limit analysis to this position in seconds"
        },
        @workers_option
      ],
      produces: "a seamlessly looping video",
      frames: :info
    },
    %{
      name: "deform",
      label: "Rig deformation",
      summary: "Puppet-warp a still image with a rig document",
      description: """
      Animates a still image (or a video's first frame) with the bones and
      keyframes of a `framer.rig` document, writing an alpha-capable animation.
      The frame count and frame rate come from the rig's `duration` unless
      `--frames` / `--fps` override them; when the output is an image
      extension a single frame is rendered instead, which is the editor's
      "render one frame" path.
      """,
      args: [
        %{name: "input", help: "still image to warp, for example still.png", required: true},
        %{
          name: "output",
          help: "destination .webm/.mov, or a .png/.jpg to render a single frame",
          required: true
        }
      ],
      options: [
        %{
          name: "rig",
          flag: "--rig",
          short: "-r",
          type: :path,
          default: nil,
          required: true,
          choices: nil,
          arg: "PATH",
          help: "Path to a framer.rig JSON document"
        },
        %{
          name: "frames",
          flag: "--frames",
          short: nil,
          type: :integer,
          default: nil,
          required: false,
          choices: nil,
          arg: "N",
          help: "Frame count (default: rig.duration.frames)",
          worker_key: nil
        },
        %{
          name: "fps",
          flag: "--fps",
          short: nil,
          type: :float,
          default: nil,
          required: false,
          choices: nil,
          arg: "FPS",
          help: "Output frame rate (default: rig.duration.fps)",
          worker_key: nil
        },
        %{
          name: "iterations",
          flag: "--iterations",
          short: "-i",
          type: :integer,
          default: 5,
          required: false,
          choices: nil,
          arg: "N",
          help: "Fixed-point LBS inversion iterations"
        },
        %{
          name: "weights",
          flag: "--weights",
          short: nil,
          type: :path,
          default: nil,
          required: false,
          choices: nil,
          arg: "PATH",
          help: "Precomputed dense-weight cache (.npz)"
        },
        %{
          name: "radius_scale",
          flag: "--radius-scale",
          short: nil,
          type: :float,
          default: nil,
          required: false,
          choices: nil,
          arg: "FACTOR",
          help: "Scale factor for every bone influence radius"
        },
        @workers_option
      ],
      produces:
        "an animation of the input driven by the rig: a .webm/.mov video, or a single image frame when the output is an image",
      frames: {:rig, "rig"}
    }
  ]

  @doc "Every catalogued operation, in the order `list` prints them."
  @spec operations() :: [operation()]
  def operations, do: @operations

  @doc "The name of every catalogued operation."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@operations, & &1.name)

  @doc "Look an operation up by its command-line name."
  @spec get(String.t()) :: operation() | nil
  def get(name) when is_binary(name), do: Enum.find(@operations, &(&1.name == name))

  @doc """
  The Port-level operations of the Python worker (`framer_worker.py`) that are
  plumbing rather than catalogued operations.
  """
  @spec port_internal_ops() :: [String.t()]
  def port_internal_ops, do: @port_internal_ops

  @doc """
  Every operation the `framer` command can reach: the catalog plus the internal
  Port operations it drives on the caller's behalf.
  """
  @spec port_operations() :: [String.t()]
  def port_operations, do: names() ++ @port_internal_ops

  @doc """
  The key an option is sent to the worker under, or `nil` when the BEAM
  consumes the option itself (worker-pool sizing, frame resolution) and the
  Python op never reads it. An option without an explicit `:worker_key` is
  forwarded under its own name.
  """
  @spec worker_key(map()) :: String.t() | nil
  def worker_key(%{} = option), do: Map.get(option, :worker_key, option.name)

  @doc "The invocation line for an operation, without the executable."
  @spec usage(operation()) :: String.t()
  def usage(%{} = operation) do
    args = Enum.map_join(operation.args, " ", &"<#{&1.name}>")
    "framer #{operation.name} #{args} [options]"
  end

  @doc "The machine-readable form of one operation."
  @spec entry_json(operation()) :: map()
  def entry_json(%{} = operation) do
    %{
      "name" => operation.name,
      "summary" => operation.summary,
      "description" => String.trim(operation.description),
      "usage" => usage(operation),
      "args" => Enum.map(operation.args, &argument_json/1),
      "produces" => operation.produces,
      "options" => Enum.map(operation.options, &option_json/1)
    }
  end

  @doc "The machine-readable catalog of every operation."
  @spec list_json() :: map()
  def list_json do
    %{
      "name" => "framer",
      "version" => version(),
      "operations" => Enum.map(@operations, &entry_json/1)
    }
  end

  @doc "The `framer` version, taken from the application."
  @spec version() :: String.t()
  def version do
    # Reading the spec needs the .app loaded, not the application started, so
    # `framer --version` answers even where the runtime cannot boot.
    _ = :application.load(:framer_core)

    case Application.spec(:framer_core, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end

  @doc "One operation as text, for `framer describe`."
  @spec render_entry(operation()) :: String.t()
  def render_entry(%{} = operation) do
    args =
      Enum.map_join(operation.args, "\n", fn arg ->
        "    <#{arg.name}>#{padding(10, "<#{arg.name}>")}#{arg.help}"
      end)

    options = Enum.map_join(operation.options, "\n", fn opt -> "    " <> option_text(opt) end)
    description = indent(String.trim(operation.description), 6)

    """
    #{operation.name}
      #{operation.summary}

      #{usage(operation)}

      Takes:
    #{args}

      Produces:
        #{operation.produces}

      Options:
    #{options}

    #{description}\
    """
  end

  @doc "Every operation as text, for `framer list`."
  @spec render_list() :: String.t()
  def render_list do
    width = @operations |> Enum.map(&String.length(&1.name)) |> Enum.max()

    entries =
      Enum.map_join(@operations, "\n\n", fn operation ->
        pad = String.duplicate(" ", width)

        """
          #{String.pad_trailing(operation.name, width)}  #{operation.summary}
          #{pad}  #{usage(operation)}
          #{pad}  produces: #{operation.produces}\
        """
      end)

    """
    framer #{version()} - #{length(@operations)} operations over the FramerCore orchestrator

    #{entries}

    Run `framer describe <operation>` for one operation's full contract, or add
    --json to either command for the machine-readable catalog.
    """
  end

  # --- rendering helpers ---

  defp argument_json(%{} = argument) do
    %{"name" => argument.name, "help" => argument.help, "required" => argument.required}
  end

  defp indent(text, spaces) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &(String.duplicate(" ", spaces) <> &1))
  end

  defp option_json(%{} = option) do
    %{
      "name" => option.name,
      "flag" => option.flag,
      "short" => option.short,
      "arg" => option.arg,
      "type" => option.type,
      "default" => option.default,
      "required" => option.required,
      "choices" => option.choices,
      "help" => option.help
    }
  end

  defp option_text(%{} = option) do
    names = if option.short, do: "#{option.flag}, #{option.short}", else: option.flag
    signature = "#{names} <#{option.arg}>"
    default = if is_nil(option.default), do: "", else: " (default: #{option.default})"

    "#{String.pad_trailing(signature, 34)}#{option.help}#{default}"
  end

  defp padding(width, text), do: String.duplicate(" ", max(width - String.length(text), 0))
end
