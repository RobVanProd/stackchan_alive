import os

Import("env")


def required(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"{name} is required for the stackchan_wifi environment")
    return value


def escaped_define_string(name, value):
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'-D{name}=\\"{escaped}\\"'


bridge_port = required("STACKCHAN_BRIDGE_PORT")
try:
    bridge_port_int = int(bridge_port)
except ValueError as exc:
    raise RuntimeError("STACKCHAN_BRIDGE_PORT must be an integer") from exc

env.Append(
    CPPDEFINES=[
        ("STACKCHAN_ENABLE_WIFI_BRIDGE", 1),
        ("STACKCHAN_BRIDGE_PORT", bridge_port_int),
    ],
    CCFLAGS=[
        escaped_define_string("STACKCHAN_WIFI_SSID", required("STACKCHAN_WIFI_SSID")),
        escaped_define_string("STACKCHAN_WIFI_PASSWORD", required("STACKCHAN_WIFI_PASSWORD")),
        escaped_define_string("STACKCHAN_BRIDGE_HOST", required("STACKCHAN_BRIDGE_HOST")),
        escaped_define_string("STACKCHAN_BRIDGE_PATH", required("STACKCHAN_BRIDGE_PATH")),
    ],
)
