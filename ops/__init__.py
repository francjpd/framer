"""
Operations module for frame.

Each operation is a function that takes input_path, output_path, and operation-specific args.
"""

from core import get_registry, register_operation

# Import operations to register them
from ops import fps_boost
from ops import remove_bg
from ops import loop

__all__ = ["fps_boost", "remove_bg"]
