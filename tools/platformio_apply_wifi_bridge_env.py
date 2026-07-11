import os

Import("env")


def optional(name):
    return os.environ.get(name, "").strip()


def escaped_define_string(name, value):
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'-D{name}=\\"{escaped}\\"'


cpp_defines = [
    ("STACKCHAN_ENABLE_WIFI_BRIDGE", 1),
]
cc_flags = []

bridge_port = optional("STACKCHAN_BRIDGE_PORT")
if bridge_port:
    try:
        cpp_defines.append(("STACKCHAN_BRIDGE_PORT", int(bridge_port)))
    except ValueError as exc:
        raise RuntimeError("STACKCHAN_BRIDGE_PORT must be an integer") from exc

for name in (
    "STACKCHAN_WIFI_SSID",
    "STACKCHAN_WIFI_PASSWORD",
    "STACKCHAN_BRIDGE_HOST",
    "STACKCHAN_BRIDGE_PATH",
):
    value = optional(name)
    if value:
        cc_flags.append(escaped_define_string(name, value))

env.Append(
    CPPDEFINES=cpp_defines,
    CCFLAGS=cc_flags,
)
