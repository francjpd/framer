"""Shared error type for the engine's rig/layer documents.

Lives on its own so `core.deform` and `core.layers` can both raise and catch the
same rig-schema error without importing each other.
"""

from __future__ import annotations


class RigError(ValueError):
    """Raised when a rig document does not satisfy the schema."""
