# Included Stackchan RVC Voice

The release includes the exact `model.pth` and `model.index` pair used by the production
DirectML worker through Git LFS.

Install it into the ignored local runtime tree:

```powershell
.\tools\install_bundled_rvc_voice.ps1
```

The production DirectML worker then uses:

- `output/voice_sources/stackchan_rvc_base/model/model.pth`
- `output/voice_sources/stackchan_rvc_base/model/model.index`

Generated WAV/MP3 files and audition pages remain local under `output/voice_auditions/` and are
not committed.
