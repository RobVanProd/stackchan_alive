# Optional Local RVC

Stackchan supports a user-supplied RVC model for local voice conversion. No RVC model,
index, converted WAV, converted MP3, or audition page is distributed with the repository,
release ZIP, or published release assets.

The operator must supply a model they are authorized to use and keep it outside the release
tree. Local review output belongs under `output/voice_auditions/`, which is ignored by Git.
The application and release scripts must never copy that output into a package automatically.

The historical Weights.gg candidate remains recorded in `data/voice_rvc_base.yaml` as
review-only provenance evidence. It is not an approved production source and is not bundled.
