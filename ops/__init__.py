"""
Operations module for frame.

Each operation is a function that takes input_path, output_path, and operation-specific args.
"""

# Import operations so their module-level @register_operation decorators run;
# importing this package is what makes the operations available to the CLI.
from ops import deform, fps_boost, loop, remove_bg

__all__ = ["deform", "fps_boost", "loop", "remove_bg"]
