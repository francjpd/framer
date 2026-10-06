"""
Basic tests for the `export` operation (`ops/export.py`).

The operation is FFmpeg-only; these tests run it against a real tiny clip and
assert the requested files appear.  FFmpeg is a hard project dependency, so the
real tests fail loudly rather than skipping when it is missing.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from core import get_registry  # noqa: E402
from ops.export import export_web  # noqa: E402


def test_export_is_registered():
    assert "export" in get_registry().list_operations()


def test_export_writes_the_requested_formats(tmp_path):
    from tests.conftest import make_clip

    clip = make_clip(tmp_path / "clip.mp4", frames=6, fps=6)
    output_dir = tmp_path / "out"

    result = export_web(str(clip), str(output_dir), format="mp4")

    assert result["success"] is True, result["error"]
    exported = output_dir / "clip.mp4"
    assert exported.exists()
    assert str(exported) in result["output_path"]


def test_export_gif_uses_the_palette_path(tmp_path):
    from tests.conftest import make_clip

    clip = make_clip(tmp_path / "clip.mp4", frames=4, fps=4)
    output_dir = tmp_path / "out"

    result = export_web(str(clip), str(output_dir), format="gif")

    assert result["success"] is True, result["error"]
    exported = output_dir / "clip.gif"
    assert exported.exists()
    assert exported.stat().st_size > 0
