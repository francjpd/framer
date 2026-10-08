"""
GPU Backend Detection & Device Management.

Supports CUDA (NVIDIA), ROCm (AMD), and MPS (Apple Silicon) backends.
Automatically falls back to CPU if no GPU is available.
"""

# Every backend below is optional: detection imports and initializes it, and
# any failure (missing package, driver, or device) simply means that backend is
# unavailable. The broad ``except Exception`` handlers are therefore deliberate
# best-effort probing, not swallowed bugs, so BLE001 (blind-except) and S110
# (try-except-pass) are suppressed for this module only.
# ruff: file-ignore[BLE001, S110] Optional GPU backends are probed by catching any failure.

import sys
import warnings
from enum import Enum
from typing import Any

_gpu_backend = None
_gpu_device = None
_gpu_array_module = None
_warned_about_cpu = False
_warned_about_gpu = False


class GPUBackend(Enum):
    CUDA = "cuda"
    ROCM = "rocm"
    MPS = "mps"
    INTEL = "intel"
    CPU = "cpu"


def get_progress_string() -> str:
    """Return a string indicating the GPU backend for progress bars. Returns empty string if CPU."""
    backend = get_backend()
    return f" [{backend.upper()}]" if backend != GPUBackend.CPU.value else ""


def notify_gpu_usage():
    """Print GPU info to user when GPU is being used for the first time."""
    global _warned_about_gpu

    if _warned_about_gpu:
        return

    backend = get_backend()
    if backend == GPUBackend.CPU.value:
        return

    _warned_about_gpu = True

    info = get_device_info()
    device_name = "GPU"

    if backend == GPUBackend.CUDA.value:
        device_name = info.get("device", {}).get("name", "NVIDIA GPU")
    elif backend == GPUBackend.ROCM.value:
        device_name = info.get("device", {}).get("name", "AMD GPU")
    elif backend == GPUBackend.MPS.value:
        device_name = "Apple Silicon (MPS)"
    elif backend == GPUBackend.INTEL.value:
        device_name = info.get("device", {}).get("name", "Intel GPU (Arc/Xe)")

    print(f"[GPU] Accelerating with {backend.upper()}: {device_name}", file=sys.stderr)


def get_backend() -> str:
    """
    Detect and return available GPU backend.

    Returns:
        'cuda', 'rocm', 'mps', or 'cpu'
    """
    global _gpu_backend

    if _gpu_backend is not None:
        return _gpu_backend

    _gpu_backend = _detect_backend()
    return _gpu_backend


def _detect_backend() -> str:
    """Detect available GPU backend."""

    # Check for CUDA (NVIDIA)
    try:
        import cupy as cp

        if cp.cuda.is_available():
            return GPUBackend.CUDA.value
    except ImportError:
        pass
    except Exception:
        pass

    # Check for ROCm (AMD)
    try:
        import cupy as cp

        if (
            cp.cuda.is_available()
            and "roc" in str(cp.cuda.Device(0).attributes.get("name", "")).lower()
        ):
            return GPUBackend.ROCM.value
    except ImportError:
        pass
    except Exception:
        pass

    # Check for MPS (Apple Silicon)
    try:
        import torch

        if torch.backends.mps.is_available():
            return GPUBackend.MPS.value
    except (ImportError, AttributeError):
        pass
    except Exception:
        pass

    # Check for Intel GPU (Arc, Iris Xe, etc.)
    # Note: Only detected if torch.xpu is available (requires Intel Extension for PyTorch)
    try:
        import torch

        # Check Intel GPU via torch.xpu (requires Intel Extension for PyTorch)
        if hasattr(torch, "xpu") and torch.xpu.is_available():
            return GPUBackend.INTEL.value
    except (ImportError, AttributeError):
        pass
    except Exception:
        pass

    # Note: We no longer fallback to /dev/dri detection because
    # without IPEX, we can't actually use the Intel GPU.
    # Users need to install: pip intel-extension-for-pytorch

    return GPUBackend.CPU.value


def is_available() -> bool:
    """Check if GPU is available for computations."""
    return get_backend() != GPUBackend.CPU.value


def get_device() -> Any:
    """
    Get device context for current backend.

    Returns:
        CuPy device, torch device, or None for CPU
    """
    global _gpu_device

    backend = get_backend()

    if backend == GPUBackend.CPU.value:
        return None

    if backend == GPUBackend.CUDA.value:
        try:
            import cupy as cp

            if _gpu_device is None:
                _gpu_device = cp.cuda.Device()
            return _gpu_device
        except Exception:
            return None

    if backend == GPUBackend.ROCM.value:
        try:
            import cupy as cp

            if _gpu_device is None:
                _gpu_device = cp.cuda.Device()
            return _gpu_device
        except Exception:
            return None

    if backend == GPUBackend.MPS.value:
        try:
            import torch

            if _gpu_device is None:
                _gpu_device = torch.device("mps")
            return _gpu_device
        except Exception:
            return None

    if backend == GPUBackend.INTEL.value:
        try:
            import torch

            if _gpu_device is None:
                _gpu_device = torch.device("xpu")
            return _gpu_device
        except Exception:
            return None

    return None


def get_array_module():
    """
    Get the array module for the current backend.

    Returns:
        cupy (for CUDA/ROCm) or torch (for MPS), or numpy for CPU
    """
    global _gpu_array_module

    if _gpu_array_module is not None:
        return _gpu_array_module

    backend = get_backend()

    if backend in (GPUBackend.CUDA.value, GPUBackend.ROCM.value):
        try:
            import cupy as cp

            _gpu_array_module = cp
            return cp
        except ImportError:
            pass

    if backend == GPUBackend.MPS.value:
        try:
            import torch

            _gpu_array_module = torch
            return torch
        except ImportError:
            pass

    if backend == GPUBackend.INTEL.value:
        try:
            import torch

            _gpu_array_module = torch
            return torch
        except ImportError:
            pass

    # Fallback to CPU
    global _warned_about_cpu
    if not _warned_about_cpu:
        warnings.warn(
            "GPU not available. Falling back to CPU. "
            "Install cupy-cuda12x (NVIDIA), or pip install intel-extension-for-pytorch (Intel Arc), "
            "or use PyTorch with MPS (Apple Silicon) for GPU acceleration.",
            UserWarning,
            stacklevel=2,
        )
        _warned_about_cpu = True

    import numpy as np

    _gpu_array_module = np
    return np


def to_device(arr, backend: str | None = None) -> Any:
    """
    Transfer numpy array to GPU memory.

    Args:
        arr: numpy array to transfer
        backend: optional backend override ('cuda', 'mps', 'cpu')

    Returns:
        GPU array (CuPy array, torch tensor, or original numpy array)
    """
    if backend is None:
        backend = get_backend()

    if backend == GPUBackend.CPU.value:
        return arr

    if backend in (GPUBackend.CUDA.value, GPUBackend.ROCM.value):
        try:
            import cupy as cp

            return cp.asarray(arr)
        except Exception as e:
            warnings.warn(f"Failed to transfer to CUDA: {e}")
            return arr

    if backend == GPUBackend.MPS.value:
        try:
            import torch

            return torch.from_numpy(arr).to("mps")
        except Exception as e:
            warnings.warn(f"Failed to transfer to MPS: {e}")
            return arr

    if backend == GPUBackend.INTEL.value:
        try:
            import torch

            return torch.from_numpy(arr).to("xpu")
        except Exception as e:
            warnings.warn(f"Failed to transfer to Intel GPU: {e}")
            return arr

    return arr


def from_device(arr) -> Any:
    """
    Transfer GPU array back to numpy.

    Args:
        arr: GPU array (CuPy array, torch tensor)

    Returns:
        numpy array
    """
    # Check if it's a CuPy array
    try:
        import cupy as cp

        if isinstance(arr, cp.ndarray):
            return cp.asnumpy(arr)
    except (ImportError, TypeError):
        pass

    # Check if it's a torch tensor
    try:
        import torch

        if isinstance(arr, torch.Tensor):
            return arr.cpu().numpy()
    except (ImportError, TypeError):
        pass

    # Already CPU array
    return arr


def device_synchronize():
    """Synchronize GPU operations if using CUDA/ROCm."""
    backend = get_backend()

    if backend in (GPUBackend.CUDA.value, GPUBackend.ROCM.value):
        try:
            import cupy as cp

            cp.cuda.Stream.null.synchronize()
        except Exception:
            pass
    elif backend == GPUBackend.MPS.value:
        try:
            import torch

            torch.mps.synchronize()
        except Exception:
            pass
    elif backend == GPUBackend.INTEL.value:
        try:
            import torch

            if hasattr(torch, "xpu"):
                torch.xpu.synchronize()
        except Exception:
            pass


def get_device_info() -> dict:
    """Get information about the available GPU device."""
    info = {
        "backend": get_backend(),
        "available": is_available(),
        "device": None,
    }

    backend = get_backend()

    if backend == GPUBackend.CUDA.value:
        try:
            import cupy as cp

            device = cp.cuda.Device()
            info["device"] = {
                "name": device.attributes.get("name", "Unknown"),
                "memory_total": device.attributes.get("totalGlobalMem", 0),
                "memory_free": device.mem.get_attr_info("size")
                if hasattr(device, "mem")
                else 0,
            }
        except Exception:
            pass

    elif backend == GPUBackend.MPS.value:
        try:
            import torch

            info["device"] = {
                "name": "Apple Silicon (MPS)",
                "memory_total": torch.mps.driver_get_max_memory(),
            }
        except Exception:
            pass

    elif backend == GPUBackend.INTEL.value:
        # Try to get Intel GPU info - default to generic name if can't read
        info["device"] = {"name": "Intel GPU (Arc/Xe)"}

    return info


def force_cpu(enabled: bool = True):
    """
    Force CPU mode, overriding GPU detection.

    Args:
        enabled: If True, force CPU mode. If False, re-enable GPU detection.
    """
    global _gpu_backend, _gpu_array_module, _gpu_device

    if enabled:
        _gpu_backend = GPUBackend.CPU.value
        _gpu_array_module = None
        _gpu_device = None
    else:
        # Reset to re-detect
        _gpu_backend = None
        _gpu_array_module = None
        _gpu_device = None
        get_backend()  # Trigger re-detection
