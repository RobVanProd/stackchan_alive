"""Pin compiler build-time inputs to a reviewed source epoch.

The Arduino core embeds ``__DATE__`` and ``__TIME__`` in firmware. Those
wall-clock strings change the ELF descriptor and the appended image digest, so
the same source can otherwise produce a different application binary.

Canonical builds derive an epoch from a clean Git HEAD. Direct diagnostic
builds without Git may set ``STACKCHAN_BUILD_EPOCH`` to a strict decimal Unix
epoch. Release packaging rejects that and every other ambient build override.
"""

from datetime import datetime, timezone
import os
from pathlib import Path
import re
import subprocess


Import("env")


_EPOCH_RE = re.compile(r"[0-9]+\Z")
_COMMIT_RE = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
_MAX_EPOCH = 253402300799  # 9999-12-31T23:59:59Z
_MONTHS = (
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
)
_FORBIDDEN_ENVIRONMENT = (
    "SOURCE_DATE_EPOCH",
    "STACKCHAN_BUILD_STAMP",
    "STACKCHAN_DISABLE_REPRODUCIBLE_BUILD",
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_CEILING_DIRECTORIES",
)
_CANONICAL_DEBUG_ROOT = "/stackchan/source"
_CANONICAL_CORE_ROOT = "/stackchan/platformio-core"


def _run_git(project_dir: Path, *arguments: str) -> str:
    git_environment = {
        key: value
        for key, value in os.environ.items()
        if not key.upper().startswith("GIT_")
    }
    git_environment["GIT_NO_REPLACE_OBJECTS"] = "1"
    try:
        result = subprocess.run(
            ["git", *arguments],
            cwd=str(project_dir),
            capture_output=True,
            check=False,
            text=True,
            timeout=10,
            env=git_environment,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise RuntimeError("Git is required for a canonical reproducible build") from exc
    if result.returncode != 0:
        raise RuntimeError("Git is required for a canonical reproducible build")
    return result.stdout.strip()


def _parse_epoch(name: str, value: str) -> int:
    if len(value) > 12 or not _EPOCH_RE.fullmatch(value):
        raise RuntimeError(f"{name} must be an exact unsigned decimal Unix epoch")
    epoch = int(value, 10)
    if epoch > _MAX_EPOCH:
        raise RuntimeError(f"{name} is outside the supported UTC date range")
    try:
        datetime.fromtimestamp(epoch, timezone.utc)
    except (OverflowError, OSError, ValueError) as exc:
        raise RuntimeError(f"{name} is outside the supported UTC date range") from exc
    return epoch


def _canonical_identity(project_dir: Path) -> tuple[str, int, str]:
    if "STACKCHAN_BUILD_EPOCH" in os.environ:
        if (
            "STACKCHAN_EXPECTED_BUILD_COMMIT" in os.environ
            or "STACKCHAN_EXPECTED_BUILD_EPOCH" in os.environ
        ):
            raise RuntimeError(
                "Direct build epoch overrides cannot satisfy a package build identity lock"
            )
        raw_epoch = os.environ["STACKCHAN_BUILD_EPOCH"]
        epoch = _parse_epoch("STACKCHAN_BUILD_EPOCH", raw_epoch)
        return "direct-epoch-override", epoch, "override"

    worktree = _run_git(project_dir, "rev-parse", "--show-toplevel")
    if not worktree or _run_git(project_dir, "rev-parse", "--is-inside-work-tree") != "true":
        raise RuntimeError("Git worktree identity could not be resolved")
    if _run_git(project_dir, "rev-parse", "--show-prefix"):
        raise RuntimeError("Git worktree identity does not match the PlatformIO project directory")

    commit = _run_git(project_dir, "rev-parse", "--verify", "HEAD").lower()
    if not _COMMIT_RE.fullmatch(commit):
        raise RuntimeError("Git HEAD did not resolve to a full hexadecimal commit ID")
    status = _run_git(
        project_dir,
        "status",
        "--porcelain=v1",
        "--untracked-files=all",
    )
    if status:
        raise RuntimeError(
            "Canonical reproducible builds require a clean Git worktree, including untracked files"
        )
    expected_commit = os.environ.get("STACKCHAN_EXPECTED_BUILD_COMMIT")
    expected_epoch = os.environ.get("STACKCHAN_EXPECTED_BUILD_EPOCH")
    if (expected_commit is None) != (expected_epoch is None):
        raise RuntimeError("Expected build commit and epoch must be supplied together")
    if expected_commit is not None:
        expected_commit = expected_commit.lower()
        if not _COMMIT_RE.fullmatch(expected_commit):
            raise RuntimeError("STACKCHAN_EXPECTED_BUILD_COMMIT is not a full commit ID")
        if commit != expected_commit:
            raise RuntimeError("Git HEAD does not match the package build identity lock")

    raw_epoch = _run_git(project_dir, "show", "-s", "--format=%ct", commit)
    epoch = _parse_epoch("Git commit epoch", raw_epoch)
    if expected_epoch is not None and epoch != _parse_epoch(
        "STACKCHAN_EXPECTED_BUILD_EPOCH", expected_epoch
    ):
        raise RuntimeError("Git commit epoch does not match the package build identity lock")
    if _run_git(project_dir, "rev-parse", "--verify", "HEAD").lower() != commit:
        raise RuntimeError("Git HEAD changed while resolving the canonical build identity")
    if _run_git(project_dir, "status", "--porcelain=v1", "--untracked-files=all"):
        raise RuntimeError("Git worktree changed while resolving the canonical build identity")
    return commit, epoch, "git-head"


def _format_builtins(epoch: int) -> tuple[str, str]:
    instant = datetime.fromtimestamp(epoch, timezone.utc)
    build_date = f"{_MONTHS[instant.month - 1]} {instant.day:2d} {instant.year:04d}"
    build_time = f"{instant.hour:02d}:{instant.minute:02d}:{instant.second:02d}"
    if len(build_date) != 11 or len(build_time) != 8:
        raise RuntimeError("Reproducible builtin formatting changed width")
    return build_date, build_time


def _prefix_map_flags(path_value: str, canonical_root: str) -> list[str]:
    """Remove one local root identity from compiler and debug metadata."""

    roots = []
    lexical = Path(os.path.abspath(path_value))
    resolved = lexical.resolve()
    for candidate in (lexical.as_posix(), resolved.as_posix()):
        candidate = candidate.rstrip("/")
        if candidate and candidate not in roots:
            if "=" in candidate:
                raise RuntimeError(
                    "PlatformIO project paths containing '=' cannot be prefix-mapped safely"
                )
            roots.append(candidate)

    return [f"-ffile-prefix-map={root}={canonical_root}" for root in roots]


def _configure_build(platformio_env) -> None:
    for variable in _FORBIDDEN_ENVIRONMENT:
        if variable in os.environ:
            raise RuntimeError(f"Unsupported reproducible-build override is present: {variable}")

    project_dir_value = str(platformio_env["PROJECT_DIR"])
    project_dir = Path(project_dir_value).resolve()
    identity, epoch, source = _canonical_identity(project_dir)
    build_date, build_time = _format_builtins(epoch)

    child_environment = platformio_env.get("ENV")
    if child_environment is None:
        child_environment = {}
        platformio_env["ENV"] = child_environment
    child_environment["SOURCE_DATE_EPOCH"] = str(epoch)

    path_flags = _prefix_map_flags(project_dir_value, _CANONICAL_DEBUG_ROOT)
    core_dir_value = platformio_env.get("PROJECT_CORE_DIR") or os.environ.get(
        "PLATFORMIO_CORE_DIR"
    )
    if core_dir_value:
        path_flags.extend(_prefix_map_flags(str(core_dir_value), _CANONICAL_CORE_ROOT))

    platformio_env.AppendUnique(
        CCFLAGS=[
            "-Wno-builtin-macro-redefined",
            f'-D__DATE__=\\"{build_date}\\"',
            f'-D__TIME__=\\"{build_time}\\"',
            *path_flags,
        ]
    )
    print(
        "[reproducible-build] "
        f"source={source} identity={identity} epoch={epoch} "
        f"date={build_date!r} time={build_time!r}"
    )


_configure_build(env)
