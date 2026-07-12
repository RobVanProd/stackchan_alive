import os
import re

Import("env")

# Keep PlatformIO child tools, especially esptool's Unicode progress display,
# independent of the Windows console's legacy code page.
os.environ["PYTHONIOENCODING"] = "utf-8"
os.environ["PYTHONUTF8"] = "1"


def optional(name):
    return os.environ.get(name, "").strip()


def escaped_define_string(name, value):
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'-D{name}=\\"{escaped}\\"'


cpp_defines = [
    ("STACKCHAN_ENABLE_WIFI_BRIDGE", 1),
]
cc_flags = []
pio_environment = env.subst("$PIOENV")

private_release_values = {
    name: optional(name)
    for name in (
        "STACKCHAN_WIFI_SSID",
        "STACKCHAN_WIFI_PASSWORD",
        "STACKCHAN_BRIDGE_HOST",
        "STACKCHAN_BRIDGE_PORT",
        "STACKCHAN_BRIDGE_PATH",
        "STACKCHAN_PAIRING_SHORT_CODE",
    )
}
if pio_environment == "stackchan_release_full" and any(private_release_values.values()):
    raise RuntimeError("stackchan_release_full forbids embedded network, bridge, or pairing values")

bridge_port = optional("STACKCHAN_BRIDGE_PORT")
if bridge_port:
    try:
        parsed_bridge_port = int(bridge_port)
    except ValueError as exc:
        raise RuntimeError("STACKCHAN_BRIDGE_PORT must be an integer") from exc
    if parsed_bridge_port < 1 or parsed_bridge_port > 65535:
        raise RuntimeError("STACKCHAN_BRIDGE_PORT must be between 1 and 65535")
    cpp_defines.append(("STACKCHAN_BRIDGE_PORT", parsed_bridge_port))
elif optional("STACKCHAN_BRIDGE_HOST"):
    # Keep embedded-host lab builds aligned with the PC and companion bridge.
    cpp_defines.append(("STACKCHAN_BRIDGE_PORT", 8765))

for name in (
    "STACKCHAN_WIFI_SSID",
    "STACKCHAN_WIFI_PASSWORD",
    "STACKCHAN_BRIDGE_HOST",
    "STACKCHAN_BRIDGE_PATH",
):
    value = optional(name)
    if value:
        cc_flags.append(escaped_define_string(name, value))

pairing_code = optional("STACKCHAN_PAIRING_SHORT_CODE")
if pio_environment.startswith("stackchan_camera_probe") and not pairing_code:
    raise RuntimeError(
        f"{pio_environment} is a private paired-camera environment and requires "
        "STACKCHAN_PAIRING_SHORT_CODE"
    )
if pairing_code:
    if re.fullmatch(r"[0-9]{6}", pairing_code) is None:
        raise RuntimeError("STACKCHAN_PAIRING_SHORT_CODE must be exactly six ASCII digits")
    cc_flags.append(escaped_define_string("STACKCHAN_PAIRING_SHORT_CODE", pairing_code))

env.Append(
    CPPDEFINES=cpp_defines,
    CCFLAGS=cc_flags,
)
