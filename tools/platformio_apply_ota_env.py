import hashlib
import os

Import("env")

# esptool 5 renders Unicode progress bars. Force every child process launched by
# production PlatformIO environments onto UTF-8 even when Windows starts pio in
# a legacy console code page.
os.environ["PYTHONIOENCODING"] = "utf-8"
os.environ["PYTHONUTF8"] = "1"


def escaped_define_string(name, value):
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'-D{name}=\\"{escaped}\\"'


raw_token = os.environ.get("STACKCHAN_OTA_TOKEN", "")
pio_environment = env.subst("$PIOENV")
if raw_token and pio_environment == "stackchan_release_full":
    raise RuntimeError("stackchan_release_full forbids embedding an OTA token")
token_required_environments = {
    "stackchan_release_forensics",
    "stackchan_camera_probe",
}
if not raw_token and pio_environment in token_required_environments:
    raise RuntimeError(
        f"{pio_environment} is an OTA production environment and requires STACKCHAN_OTA_TOKEN"
    )
if raw_token:
    if raw_token != raw_token.strip():
        raise RuntimeError("STACKCHAN_OTA_TOKEN must not have leading or trailing whitespace")
    token_bytes = raw_token.encode("utf-8")
    if len(token_bytes) < 32 or len(token_bytes) > 128:
        raise RuntimeError("STACKCHAN_OTA_TOKEN must be 32 to 128 UTF-8 bytes")
    if any(byte < 0x21 or byte > 0x7E for byte in token_bytes):
        raise RuntimeError("STACKCHAN_OTA_TOKEN must contain printable ASCII without spaces")

    token_sha256 = hashlib.sha256(token_bytes).hexdigest()
    cpp_defines = [("STACKCHAN_ENABLE_LAN_OTA", 1)]
    ota_port = os.environ.get("STACKCHAN_OTA_PORT", "").strip()
    if ota_port:
        try:
            parsed_port = int(ota_port)
        except ValueError as exc:
            raise RuntimeError("STACKCHAN_OTA_PORT must be an integer") from exc
        if parsed_port < 1024 or parsed_port > 65535:
            raise RuntimeError("STACKCHAN_OTA_PORT must be between 1024 and 65535")
        cpp_defines.append(("STACKCHAN_OTA_PORT", parsed_port))

    env.Append(
        CPPDEFINES=cpp_defines,
        CCFLAGS=[escaped_define_string("STACKCHAN_OTA_TOKEN_SHA256", token_sha256)],
    )
