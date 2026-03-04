#!/usr/bin/env python3
"""
CLI tool for video processing with operations like background removal, FPS boost, etc.

Usage:
    python cli.py <input> <output> <operation> [options...]
    python cli.py <input> <output> <operation> --config config.json

Operations:
    remove-bg - Remove background with alpha channel
    fps-boost - Increase video frame rate

Options:
    --config, -c  Path to JSON config file (exclusive with other options)

Examples:
    python cli.py input.mp4 output.webm remove-bg --tolerance 30
    python cli.py input.mp4 output.mp4 fps-boost --to 60
    python cli.py input.mp4 output.webm remove-bg --config pipeline.json
"""

import argparse
import sys
import json
from pathlib import Path

# Import operations
from ops import get_registry


def parse_color(color_str):
    """Parse color from BGR string or hex."""
    if color_str is None:
        return None

    if isinstance(color_str, (list, tuple)):
        if len(color_str) == 3:
            return list(color_str)
        return None

    if isinstance(color_str, str):
        color_str = color_str.strip()
        if color_str.startswith("#"):
            color_str = color_str[1:]

        if len(color_str) == 6:
            try:
                r = int(color_str[0:2], 16)
                g = int(color_str[2:4], 16)
                b = int(color_str[4:6], 16)
                return [b, g, r]
            except ValueError:
                pass

        try:
            values = [int(x.strip()) for x in color_str.split(",")]
            if len(values) == 3:
                return values
        except ValueError:
            pass

    return None


def main():
    registry = get_registry()
    available_ops = registry.list_operations()

    parser = argparse.ArgumentParser(
        description="Video processing CLI with composable operations",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""
Operations:
{chr(10).join(f"  {name.replace("-", "_")}: {op["description"]}" for name, op in available_ops.items())}

Examples:
  python cli.py input.mp4 output.webm remove_bg --tolerance 30
  python cli.py input.mp4 output.mp4 fps_boost --to 60
  python cli.py input.mp4 output.webm remove_bg --config pipeline.json
""",
    )

    parser.add_argument("input", help="Input video file")
    parser.add_argument("output", help="Output video file")

    # Add config flag (applies to all operations, exclusive with other args)
    parser.add_argument(
        "-c",
        "--config",
        dest="config",
        help="Path to JSON config file (exclusive with other options)",
    )

    # Add subparsers for each operation
    subparsers = parser.add_subparsers(
        dest="operation", required=True, help="Operation to perform"
    )

    # Track which subparsers we've added
    added_ops = set()

    for name, op_info in available_ops.items():
        # Normalize name for argparse (replace hyphens with underscores for subcommand name)
        normalized_name = name.replace("-", "_")

        if normalized_name in added_ops:
            continue
        added_ops.add(normalized_name)

        subparser = subparsers.add_parser(normalized_name, help=op_info["description"])

        # Get args schema for this operation
        schema = op_info["args_schema"]

        for arg_name, arg_info in schema.items():
            # Convert snake_case to --arg-name
            flag_name = f"--{arg_name.replace('_', '-')}"
            arg_type = arg_info.get("type", "string")

            # Map types
            if arg_type == "int":
                type_func = int
            elif arg_type == "float":
                type_func = float
            elif arg_type == "bool":
                type_func = lambda x: x.lower() != "false"
            else:
                type_func = str

            default = arg_info.get("default")

            # Build argument flags - support short flags
            flag_args = [flag_name]
            short_flag = arg_info.get("short")
            if short_flag:
                flag_args.insert(0, short_flag)

            if arg_type == "bool":
                # Use store_true/store_false for boolean flags
                if default is False:
                    subparser.add_argument(
                        *flag_args,
                        action="store_true",
                        dest=arg_name,
                        help=arg_info.get("description", ""),
                    )
                else:
                    subparser.add_argument(
                        *flag_args,
                        action="store_false",
                        dest=arg_name,
                        help=arg_info.get("description", ""),
                    )
            else:
                subparser.add_argument(
                    *flag_args,
                    type=type_func,
                    default=default,
                    dest=arg_name,
                    help=arg_info.get("description", ""),
                )

    args = parser.parse_args()

    # Get operation info
    # Convert underscores back to hyphens for registry lookup
    op_name = args.operation.replace("_", "-")
    op_info = registry.get(op_name)

    if not op_info:
        print(f"Error: Unknown operation '{op_name}'")
        print(f"Available operations: {list(available_ops.keys())}")
        sys.exit(1)

    # Check for config exclusivity
    config = getattr(args, "config", None)

    if config:
        # Validate no other options were passed (except input/output/operation)
        passed_args = {}

        # Get all parsed args (exclude special keys)
        parsed_args = {
            k: v
            for k, v in vars(args).items()
            if k not in ["input", "output", "operation", "config"]
        }

        # Check which ones were explicitly passed vs default
        schema = op_info["args_schema"]

        for arg_name, value in parsed_args.items():
            arg_info = schema.get(arg_name, {})
            arg_type = arg_info.get("type", "string")
            default = arg_info.get("default")

            # Skip if value matches default
            if arg_type == "bool":
                # store_true stores False by default, True when flag passed
                # store_false stores True by default, False when flag passed
                actual_default = arg_info.get("default", False)
                if value != actual_default:
                    passed_args[arg_name] = value
            elif value is not None and value != default:
                passed_args[arg_name] = value

        if passed_args:
            print(
                f"Error: --config is exclusive. Cannot use other flags when config is specified."
            )
            print(f"Passed conflicting args: {list(passed_args.keys())}")
            sys.exit(1)

        # Load config
        config_path = Path(config)
        if not config_path.exists():
            print(f"Error: Config file not found: {config}")
            sys.exit(1)

        with open(config_path) as f:
            config_data = json.load(f)

        op_config = config_data.get(args.operation, {})
        op_args = op_config
    else:
        # Build args from parsed values (exclude None/empty)
        op_args = {
            k: v
            for k, v in vars(args).items()
            if k not in ["input", "output", "operation", "config"] and v is not None
        }

        # Convert color if provided
        if "color" in op_args:
            op_args["color"] = parse_color(op_args["color"])

    # Import global flags and inject them into operation args
    from core import GLOBAL_FLAGS

    # Add global flags to operation args
    for flag_name in GLOBAL_FLAGS.keys():
        if hasattr(args, flag_name):
            op_args[flag_name] = getattr(args, flag_name)

    # Execute operation
    try:
        result = op_info["func"](
            input_path=args.input, output_path=args.output, **op_args
        )

        if result.get("success"):
            print(f"\n✅ Success! Output: {result['output_path']}")
        else:
            print(f"\n❌ Error: {result.get('error', 'Unknown error')}")
            sys.exit(1)

    except Exception as e:
        print(f"\n❌ Error: {str(e)}")
        sys.exit(1)


if __name__ == "__main__":
    main()
