"""Make firmware images byte-reproducible for a given source commit.

Two clean builds of identical source used to produce different binaries. The
cause is `chip-debug-report.cpp` in the Arduino core, which prints

    chip_report_printf("  Compile Date/Time : %s %s\\n", __DATE__, __TIME__);

Those two builtin macros expand to the wall-clock time of the build, so the
string differs between builds. Everything downstream then differs too: the
`app_elf_sha256` field in `esp_app_desc_t`, and the SHA-256 esptool appends to
the image. Three bytes of real difference became a different firmware hash.

That matters because the release process binds an exact firmware SHA-256 to
recorded hardware evidence. Without reproducibility a paired record can only be
"trust this archived artifact"; with it, anyone can rebuild the commit and check.

This replaces both macros with values derived from the source commit, so the same
commit always yields the same image while the banner still identifies the build.
Redefining builtin macros needs -Wno-builtin-macro-redefined.

Set STACKCHAN_BUILD_STAMP to override the derived value; set
STACKCHAN_DISABLE_REPRODUCIBLE_BUILD=1 to keep the wall-clock behaviour.
"""

import os
import subprocess

Import("env")


def _git(*args):
    try:
        out = subprocess.run(
            ["git", *args],
            cwd=env["PROJECT_DIR"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def _build_stamp():
    override = os.environ.get("STACKCHAN_BUILD_STAMP", "").strip()
    if override:
        return override[:24]

    commit = _git("rev-parse", "--short=12", "HEAD")
    if not commit:
        # No git available: still deterministic, just less informative.
        return "nogit"
    dirty = _git("status", "--porcelain", "--untracked-files=no")
    return f"{commit}{'+dirty' if dirty else ''}"


if os.environ.get("STACKCHAN_DISABLE_REPRODUCIBLE_BUILD", "").strip() not in ("", "0"):
    print("[reproducible-build] disabled; images will embed wall-clock build time")
else:
    stamp = _build_stamp()
    # __DATE__ carries the commit, __TIME__ marks how it was pinned. Neither is
    # parsed anywhere; the Arduino core only prints them.
    env.Append(
        CCFLAGS=[
            "-Wno-builtin-macro-redefined",
            f'-D__DATE__=\\"{stamp}\\"',
            '-D__TIME__=\\"reproducible\\"',
        ]
    )
    print(f"[reproducible-build] pinned __DATE__/__TIME__ to '{stamp} reproducible'")
