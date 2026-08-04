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

The reviewed pioarduino core is sealed before allowlist review with
`tools/seal_pioarduino_release_core.ps1`. Upstream `penv_setup.py` keyed its pinned core URL as
`platformio`, while the installed distribution is named `pioarduino-core`; that mismatch caused
every build to reinstall the same 6.1.18 core and alternately swap `urllib3` 2.7.0/1.26.20. The
seal recognizes both names while retaining the exact v6.1.18 comparison and URL. It accepts only
the reviewed original SHA-256, writes and verifies a private original-byte backup, atomically
installs only the reviewed patched SHA-256, and also validates the backup on already-sealed runs.
It is a trusted-source provisioning step, not an archive-side authority or a package-time repair.

The Python claim additionally requires an exact process isolation state. The caller must set
`PYTHONNOUSERSITE=1`, `PYTHONSAFEPATH=1`, `PYTHONDONTWRITEBYTECODE=1`, `PYTHONHASHSEED=0`,
`PYTHONUTF8=1`, and `PYTHONIOENCODING=utf-8`, and must remove the ambient Python, virtualenv, and
Conda override variables rejected by the helper, including any ambient `PYTHONOPTIMIZE`. The
selected runtime is executed before hashing and must report `no_user_site=1`, safe-path mode,
disabled bytecode writes, `optimize=0`, its exact installation
as both prefix values, and exactly this ordered import path: `python312.zip`, `DLLs`, `Lib`, the
installation root, and `Lib/site-packages`. Any `.pth`, `.egg-link`, `sitecustomize.py`, or
`usercustomize.py` anywhere under the installation fails closed before the runtime is started.

The post-build `.pio/libdeps` identity uses `stackchan.canonical-libdeps.v1`. Every source, header, build
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

`verify_git_pack_semantics.py` independently decodes the observed SHA-1 Git pack formats, including
OFS/REF deltas, and proves object-to-offset, CRC, reverse-index, object-ID, and checksum linkage under
bounded resource limits. Its own source bytes are a reviewed pre-build component. Clean B/C roots
independently produced identical canonical libdeps identities for all three release environments.
Those closures permit reviewed `PostBuild` assertions and candidate generation; they do not by
themselves establish a reproducible release package or authorize hardware use.

## Integration API

Dot-source the helper and call `PreBuild` before the first trusted Git/build-tool execution. After
each environment's dependency staging, call its environment-filtered `PostBuild` assertion before
clean/build, then repeat it after the build. The packager and independent verifier enforce this
ordering and require the complete record set.

The guarded PreBuild holds read leases for existing bytes, recursive namespace watchers, and a
namespace baseline until final closure. After the allowlist comparison and isolated Python probe
succeed, it stores an immutable copy of the observed PreBuild records bound to the exact allowlist
hash, platform key, four installed roots, and three executable paths. Guarded PostBuild first
performs a namespace-verified mutation barrier, revalidates every cached record against the current
leased allowlist, and then hashes only the fresh environment libdeps. It never reuses a cache after
the PreBuild scope closes, across a different authority binding, or in the PreBuild scope itself.
This removes repeated multi-gigabyte reads without allowing same-path or create/delete drift.

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
  gitHome = 'C:\Program Files\Git'
  legacyCore = 'C:\path\to\.platformio'
  releaseCore = 'C:\spio\pioarduino'
  projectRoot = (Get-Location).Path
  libdepsRoot = (Join-Path (Get-Location).Path '.pio/libdeps')
}
$leaseState = New-StackchanToolchainLeaseState
Assert-StackchanReleaseToolchainIdentity `
  -AllowlistPath tools/release_toolchain_identity_allowlist.json `
  -RootMap $roots `
  -PlatformioExecutable C:\path\to\Python312\Scripts\platformio.exe `
  -PythonExecutable C:\path\to\Python312\python.exe `
  -GitExecutable 'C:\Program Files\Git\cmd\git.exe' `
  -Phase PreBuild `
  -LeaseState $leaseState `
  -LeaseScope pre-build
# Stage dependencies for one environment, authenticate them, then build.
Assert-StackchanReleaseToolchainIdentity `
  -AllowlistPath tools/release_toolchain_identity_allowlist.json `
  -RootMap $roots `
  -PlatformioExecutable C:\path\to\Python312\Scripts\platformio.exe `
  -PythonExecutable C:\path\to\Python312\python.exe `
  -GitExecutable 'C:\Program Files\Git\cmd\git.exe' `
  -Phase PostBuild `
  -Environment stackchan `
  -LeaseState $leaseState `
  -LeaseScope cycle-a
# Close each detached-worktree dependency scope before removing that worktree.
Close-StackchanToolchainLeaseScope -LeaseState $leaseState -Scope cycle-a -RequireUnchanged
# Final success requires the full guarded namespace closure.
Close-StackchanToolchainLeaseState -LeaseState $leaseState -RequireUnchanged
```

The selected PlatformIO and Python executables must resolve to the reviewed Python installation.
The allowlist must contain exactly `Scripts/pio.exe`, `Scripts/platformio.exe`, and `python.exe`;
extra or substituted executable paths fail before hashing. Replacing a same-path launcher or
runtime changes the complete installation identity. These variables must remain in force for the
governed PlatformIO invocation; the assertion proves the same import state that the launcher will
inherit, not a separate `python -I` mode that the package invocation does not use.

## Review/update workflow

`new_release_toolchain_identity_candidate.ps1` writes a new, unreviewed, create-only candidate
under `output/private/toolchain-identity-candidates/`. It refuses output elsewhere and cannot
overwrite the tracked allowlist.
Review the exact package sources, every component, the 22 version pins in
`requirements-firmware-release.txt`, and the candidate diff. Only then may a reviewer set
`review.status=reviewed` and record non-empty `reviewer` and `reason` fields in a committed
allowlist. Never promote a candidate merely because it was generated by the same host being
checked. The current tracked policy was promoted only after independent recomputation of all 24
components, source-byte confirmation, and clean B/C canonical equality for all three environments.
Every future candidate requires a fresh independent review; the current review cannot transfer to
changed bytes.

## Retained analysis evidence

The retained clean B/C roots are `D:\CodexArtifacts\stackchan-toolchain-all-repro-b` and
`D:\CodexArtifacts\stackchan-toolchain-all-repro-c`. Both independently match these reviewed
canonical libdeps identities:

- `stackchan` and `stackchan_servo_calibration`:
  `79C18DC5078CAB8A35CCB4DAD385FDCB2BFB11126C778975F74C8F4B7096279B`;
- `stackchan_release_full`:
  `74B343038114CC2E90927E1C641B14D47806EA0759BF0FED711235B61C705273`.

The failed A root and older candidates remain rejected evidence and are not release inputs. The
reviewed tracked allowlist was derived from candidate
`release_toolchain_identity_allowlist_candidate_20260803-201018.json`, candidate SHA-256
`7E89C23B11783E66228A0A7C12F94E7AB0A0BC85D393ACF4A7C46F1AEE594CF4`. Promotion approved only
the byte policy; release eligibility still requires the packager/verifier record and artifact gates.

## Portability and CI limit

An installed-byte candidate is explicitly scoped as `exact-host-installed-bytes` and
`portableAcrossHosts=false`. A local Windows candidate is not a GitHub-hosted-runner identity.
Hosted `setup-python` baselines, path-embedded bytecode, unpinned wheel files, and PlatformIO-owned
`penv` contents can differ even when visible versions match. The tag release job therefore targets
the explicitly provisioned `stackchan-release-toolchain-20260803` self-hosted Windows runner and
passes repository-variable paths as explicit arguments. A missing, different, or hosted toolchain
fails the reviewed identity rather than silently claiming equivalence.

A portable CI design requires a fixed-path isolated Python environment, a reviewed wheelhouse with
SHA-256-pinned requirements installed using `--require-hashes --no-deps`, bytecode generation
disabled (`PYTHONDONTWRITEBYTECODE=1`) with bytecode absent before use, and separate reviewed
allowlists for each OS/architecture/runtime image. Exact version pins alone are necessary but not
sufficient. This repository's current offline evidence cannot supply trustworthy wheel hashes.

The current pre-build proof still does not byte-identify Windows system DLLs or the kernel. The
import closure is exact only under the required process environment and reported `sys.path`. The
packager and verifier constrain `PATH`, reject ambient Python/Git/PlatformIO overrides, and bind the
complete selected Git and Python installations, but this remains a host-installed-byte policy—not
a claim that the operating system itself is hermetic.

The reviewed PreBuild closure covers about 5.98 GiB and 88,000 files on the Windows host. That full
byte cost is intentional and is paid once per governed packager/verifier process. Subsequent
guarded PostBuild checks still verify every watched namespace and revalidate the cached records,
but rehash only the selected environment's fresh libdeps. Ordinary developer builds do not run
this release-authorizing proof.

The semantic verifier relies on Git's SHA-1 object identity and supports the reviewed formats: Git
pack v2/v3, pack index v2, reverse index v1, repository index v2, and SHA-1 objects. It fully decodes
ordinary and delta objects and proves offsets, CRCs, reverse mapping, and checksums with explicit
resource caps. New hash algorithms, index/pack extensions, or package-manager metadata formats
require review and a contract update; unknown forms fail closed.
