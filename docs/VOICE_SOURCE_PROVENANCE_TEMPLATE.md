# Production Voice Release Record

Stackchan: Alive releases the exact DirectML RVC files used on the reference robot.

## Active Files

- Model: `media/voice/rvc/model.pth`
- Model bytes: `57577722`
- Model SHA-256: `1A8ADDFD670CD811D1AD1EEB9E9B4FF72C5D795B1123A23E86A0C41C1DD9BF1A`
- Index: `media/voice/rvc/model.index`
- Index bytes: `99428699`
- Index SHA-256: `DA0EDB00FB15E8CEEC135B261F32E5907BA570FF0D213BEF8267EB80AB167DC2`
- Runtime: DirectML RVC
- Release record: created and owned by the repository owner, then released for public distribution
  on 2026-07-12
- Voice source commit: `996b7e4b2de0c529a0f0e508891dec33598bf935`

## Runtime Settings

- Pitch: `2`
- Index rate: `0.62`
- RMS mix: `0.72`
- Protect: `0.28`
- F0 method: `pm`

Run `tools/verify_tracked_rvc_assets.ps1` to verify the exact files before packaging.
