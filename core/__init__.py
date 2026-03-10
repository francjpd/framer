"""
Core module for frame - video processing pipeline.
"""

import tempfile
import shutil
from pathlib import Path
from typing import Dict, Any, List, Callable, Optional


class Pipeline:
    """Execute a pipeline of operations on video files."""

    def __init__(self):
        self.operations: List[Dict[str, Any]] = []
        self.temp_dir = None

    def add_operation(self, name: str, func: Callable, args: Dict[str, Any]):
        """Add an operation to the pipeline."""
        self.operations.append({"name": name, "func": func, "args": args})

    def execute(self, input_path: str, output_path: str) -> Dict[str, Any]:
        """Execute all operations in sequence."""
        self.temp_dir = Path(tempfile.mkdtemp())

        current_input = input_path
        temp_files = []

        try:
            for i, op in enumerate(self.operations):
                # Determine output (use final output for last op, temp for others)
                if i == len(self.operations) - 1:
                    current_output = output_path
                else:
                    current_output = str(
                        self.temp_dir / f"step_{i}_{Path(output_path).name}"
                    )
                    temp_files.append(current_output)

                # Execute operation
                result = op["func"](
                    input_path=current_input, output_path=current_output, **op["args"]
                )

                if not result.get("success", False):
                    return result

                # Pass output as next input
                current_input = current_output

            return {"success": True, "output_path": output_path}

        finally:
            # Cleanup temp files
            for tf in temp_files:
                try:
                    Path(tf).unlink(missing_ok=True)
                except:
                    pass

            # Cleanup temp directory
            if self.temp_dir and self.temp_dir.exists():
                try:
                    shutil.rmtree(self.temp_dir)
                except:
                    pass


class OperationRegistry:
    """Registry of available operations."""

    def __init__(self):
        self._operations: Dict[str, Dict[str, Any]] = {}

    def register(
        self,
        name: str,
        func: Callable,
        args_schema: Dict[str, Any],
        description: str = "",
    ):
        """Register an operation."""
        # Merge global flags into args_schema
        merged_schema = {**GLOBAL_FLAGS, **args_schema}
        self._operations[name] = {
            "func": func,
            "args_schema": merged_schema,
            "description": description,
        }

    def get(self, name: str) -> Optional[Dict[str, Any]]:
        """Get operation by name."""
        return self._operations.get(name, {})

    def list_operations(self) -> Dict[str, Dict[str, Any]]:
        """List all registered operations."""
        return self._operations

    def get_args_schema(self, name: str) -> Dict[str, Any]:
        """Get args schema for operation."""
        op = self._operations.get(name)
        return op["args_schema"] if op else {}


# Global flags - automatically added to all operations
GLOBAL_FLAGS = {
    "progress": {
        "type": "bool",
        "default": False,
        "short": "-p",
        "description": "Show progress bar",
    },
    "force_cpu": {
        "type": "bool",
        "default": False,
        "description": "Force CPU mode, disable GPU acceleration",
    },
}


# Global registry instance
_registry = OperationRegistry()


def get_registry() -> OperationRegistry:
    """Get the global operation registry."""
    return _registry


def register_operation(
    name: str,
    func=None,
    args_schema=None,
    description: str = "",
):
    """Register an operation. Can be used as decorator or direct call."""

    # Allow both decorator and direct usage
    if func is None:
        # Used as decorator: @register_operation(...)
        def decorator(f):
            _registry.register(name, f, args_schema or {}, description)
            return f

        return decorator
    else:
        # Direct call: register_operation(name, func, args_schema)
        _registry.register(name, func, args_schema or {}, description)
        return func
