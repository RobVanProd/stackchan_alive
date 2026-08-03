# Release Toolchain Byte Identity

Version strings and `pio pkg list` output are not toolchain identity. A launcher can lie about its
version, while framework, compiler, Python, SCons, or library bytes can change under unchanged
paths and versions. `release_toolchain_identity.ps1` computes a canonical SHA-256 inventory over
the exact installed inputs used by the three release firmware environments.

The pre-build identity is path-independent: each component hashes normalized relative path, byte
count, and file SHA-256 in ordinal order. It does not hash absolute paths or filesystem
timestamps. It rejects reparse points, unsafe/non-normalized paths, and case-ambiguous
inventories. It has no implicit file exclusions. The complete Python installation is one closed
component, so `python312.zip`, `DLLs`, `Lib`, every site-package, `python.exe`, and every file in
`Scripts` are bound together. Both PlatformIO core `penv` trees, platforms, frameworks, compiler
packages, and tools are also hashed.

The Python claim additionally requires an exact process isolation state. The caller must set
`PYTHONNOUSERSITE=1`, `PYTHONSAFEPATH=1`, `PYTHONDONTWRITEBYTECODE=1`, `PYTHONHASHSEED=0`,
`PYTHONUTF8=1`, and `PYTHONIOENCODING=utf-8`, and must remove the ambient Python, virtualenv, and
Conda override variables rejected by the helper, including any ambient `PYTHONOPTIMIZE`. The
selected runtime is executed before hashing and must report `no_user_site=1`, safe-path mode,
disabled bytecode writes, `optimize=0`, its exact installation
as both prefix values, and exactly this ordered import path: `python312.zip`, `DLLs`, `Lib`, the
installation root, and `Lib/site-packages`. Any `.pth`, `.egg-link`, `sitecustomize.py`, or
`usercustomize.py` anywhere under the installation fails closed before the runtime is started.

The analysis-only post-build `.pio/libdeps` identity uses `stackchan.canonical-libdeps.v1`. Every source, header, build
script, hidden executable file, and registry-package byte remains exact. Only five proven
package-manager/VCS representation classes are canonicalized, each with separate validation:

- `integrity.dat` line order becomes an exact duplicate-free requirement set;
- PlatformIO's timestamp-only SCServo `library.json` and `.git/.piopm` labels are correlated,
  while package name, GitHub URI, reviewed commit, and all other fields remain bound;
- Git index v2 stat fields are removed only after checksum validation, while modes, object IDs,
  stages/flags, paths, and extensions remain bound;
- reflog actor/time fields are removed only after strict parsing, while old/new object IDs,
  log path, and action message remain bound;
- pack/idx/rev representation is reduced to the exact Git object-ID set only after validating
  pack SHA-1, index SHA-1, reverse-index checksum/permutation, and pack-name linkage.

Non-sample hooks, replace refs, loose/unexpected objects, alternates, grafts, dangerous Git config,
unreviewed sources, wrong commits, missing Git evidence, ambiguous metadata, and unexpected files
fail closed. Git config, refs, HEAD, packed refs, shallow state, hook samples, and all other hidden
state remain exact records. The fresh-install shape and exact requirement set are hard-coded for
each of the three release environments, so stale libraries or duplicate version directories are
rejected before candidate generation.

This canonical form is not currently eligible release evidence. The local parser validates pack,
index, and reverse-index checksums and binds the advertised Git object-ID set, but it does not
independently decode every packed object/delta to prove that index object-to-offset mappings match
the pack. Calling an installed `git verify-pack` would move that trust to an executable/runtime not
yet included in the exact pre-build identity. Fresh reproducibility evidence also exists only for
`stackchan`, not the other two release environments. Therefore `PostBuild` and candidate generation
are deliberately disabled and fail closed.

## Integration API

Dot-source the helper and call the assertion immediately before the first build. `PostBuild` is a
reserved fail-closed phase until the dependency trust limits below are closed.

```powershell
. tools/release_toolchain_identity.ps1
$env:PYTHONNOUSERSITE = '1'
$env:PYTHONSAFEPATH = '1'
$env:PYTHONDONTWRITEBYTECODE = '1'
$env:PYTHONHASHSEED = '0'
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
# Also clear every forbidden override named by Assert-StackchanPythonImportIsolation.
$roots = @{
  pythonHome = 'C:\path\to\Python312'
  legacyCore = 'C:\path\to\.platformio'
  releaseCore = 'C:\spio\pioarduino'
  projectRoot = (Get-Location).Path
}
Assert-StackchanReleaseToolchainIdentity `
  -AllowlistPath tools/release_toolchain_identity_allowlist.json `
  -RootMap $roots `
  -PlatformioExecutable C:\path\to\Python312\Scripts\platformio.exe `
  -PythonExecutable C:\path\to\Python312\python.exe `
  -Phase PreBuild
# Run the governed clean build here. This remains intentionally blocked:
Assert-StackchanReleaseToolchainIdentity `
  -AllowlistPath tools/release_toolchain_identity_allowlist.json `
  -RootMap $roots `
  -PlatformioExecutable C:\path\to\Python312\Scripts\platformio.exe `
  -PythonExecutable C:\path\to\Python312\python.exe `
  -Phase PostBuild
```

The selected PlatformIO and Python executables must resolve to the reviewed Python installation.
The allowlist must contain exactly `Scripts/pio.exe`, `Scripts/platformio.exe`, and `python.exe`;
extra or substituted executable paths fail before hashing. Replacing a same-path launcher or
runtime changes the complete installation identity. These variables must remain in force for the
governed PlatformIO invocation; the assertion proves the same import state that the launcher will
inherit, not a separate `python -I` mode that the package invocation does not use.

## Review/update workflow

`new_release_toolchain_identity_candidate.ps1` writes an unreviewed candidate under
`output/private/toolchain-identity-candidates/`. It refuses to overwrite the tracked allowlist.
Review the exact package sources, every component, the 22 version pins in
`requirements-firmware-release.txt`, and the candidate diff. Only then may a reviewer set
`review.status=reviewed` and record non-empty `reviewer` and `reason` fields in a committed
allowlist. Never promote a candidate merely because it was generated by the same host being
checked. Candidate generation includes PostBuild and therefore currently refuses every candidate.
All three environments need independent fresh-install evidence, and Git pack semantics need an
independently trusted validator, before a new candidate can be reviewed.

## Retained analysis evidence

The only retained pristine external tree used by this slice is
`D:\CodexArtifacts\stackchan-toolchain-libdeps-repro-2`. For `stackchan`, its canonical identity is
`4D18A5A5A8F385BA8CB6A88429F82240797459A76A2716A8A209D4223AA104F8` over 1,243 raw files and
166,158,472 raw bytes, producing 1,237 canonical records and 165,978,723 canonical bytes.

`D:\CodexArtifacts\stackchan-toolchain-libdeps-repro` was mutated by a build and is discarded. It
is not used for equality, reproducibility, Git representation, or any other supporting claim.
The contract instead creates two controlled local clones independently. It verifies canonical
equality across distinct PlatformIO install timestamps and tests that actual source bytes,
`builder.py`, HEAD, the branch ref, the complete reviewed commit, hooks, remote configuration,
package metadata, and pack corruption remain bound or fail closed.

The earlier candidate
`release_toolchain_identity_allowlist_candidate_20260803-143148.json` is rejected: it used raw
libdeps identities and captured a stale extra `M5GFX@0.2.24` tree. No tracked reviewed allowlist
exists.

## Portability and CI limit

An installed-byte candidate is explicitly scoped as `exact-host-installed-bytes` and
`portableAcrossHosts=false`. A local Windows candidate is not a GitHub-hosted-runner identity.
Hosted `setup-python` baselines, path-embedded bytecode, unpinned wheel files, and PlatformIO-owned
`penv` contents can differ even when visible versions match. No reviewed allowlist is committed
until that environment exists, so release verification must fail closed rather than silently
claiming toolchain eligibility.

A portable CI design requires a fixed-path isolated Python environment, a reviewed wheelhouse with
SHA-256-pinned requirements installed using `--require-hashes --no-deps`, bytecode generation
disabled (`PYTHONDONTWRITEBYTECODE=1`) with bytecode absent before use, and separate reviewed
allowlists for each OS/architecture/runtime image. Exact version pins alone are necessary but not
sufficient. This repository's current offline evidence cannot supply trustworthy wheel hashes.

The current pre-build proof still does not byte-identify Windows system DLLs, the kernel, or every
program a package may resolve from `PATH`. The import closure is exact only under the required
process environment and reported `sys.path`. This is a host-installed-byte policy, not a claim
that Python or PlatformIO is hermetic from the operating system. The Git executable used during
analysis is also not byte-identified; it cannot authorize PostBuild, which remains disabled.

The rejected raw candidate covered more than 6.1 GB on the reviewed Windows host; a strict pass exceeded two
minutes in local measurement. That cost is intentional and should be paid once before and once
after the governed release build, not on ordinary developer builds.

The analysis parser relies on Git's SHA-1 object identity and supports only the observed formats:
index v2, pack index v2, reverse index v1, and SHA-1 packs. It validates checksums, reverse-index
permutations, pack linkage, sources, commits, and object-ID inventories, but does not fully decode
pack deltas or prove index offsets/CRCs against decoded objects. New index, hash, extension,
loose-object, or package-manager metadata formats require review and a contract update. Until an
exactly identified Git/runtime or an independent pack decoder closes this gap, PostBuild remains
disabled rather than treating a useful analysis identity as release authorization.
