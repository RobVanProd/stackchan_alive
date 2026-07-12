# Included Stackchan RVC Voice

The release includes `stackchan_voice_weightsgg_model.zip` through Git LFS. The archive contains
`model.pth`, `model.index`, and its original `metadata.json` without modification.

Install it into the ignored local runtime tree:

```powershell
.\tools\install_bundled_rvc_voice.ps1
```

The production DirectML worker then uses:

- `output/voice_sources/stackchan_rvc_base/model/model.pth`
- `output/voice_sources/stackchan_rvc_base/model/model.index`

Generated WAV/MP3 files and audition pages remain local under `output/voice_auditions/` and are
not committed. See `MODEL_NOTICE.md` for the archive's preserved provenance metadata.
