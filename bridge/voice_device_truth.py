"""Side-effect-free accelerator identity probes for voice worker health."""

from __future__ import annotations


def torch_device_truth(requested_device: str) -> tuple[str, bool]:
    """Return the adapter name PyTorch exposes without moving any tensors."""

    device = str(requested_device or "").strip()
    try:
        import torch

        if device.startswith("cuda"):
            available = bool(torch.cuda.is_available())
            if not available:
                return "unavailable", False
            index = int(device.partition(":")[2] or "0")
            return str(torch.cuda.get_device_name(index)), True
        if device.startswith("cpu"):
            return "CPU", True
    except (ImportError, RuntimeError, ValueError, AssertionError):
        return device or "unknown", False
    return device or "unknown", False


def directml_device_truth(requested_device: str) -> tuple[str, bool]:
    device = str(requested_device or "").strip()
    try:
        import torch_directml

        name = str(torch_directml.device_name(0)).replace("\x00", "").strip()
    except (ImportError, RuntimeError, ValueError, AttributeError):
        return device or "unknown", False
    return name or device or "unknown", bool(name)
