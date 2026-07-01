# Voice Source Provenance Template

This template records the final production voice source for Stackchan Spark. The current WAVs are prototype audition samples only. Do not use this template to approve consumer rollout until the production source is licensed, owned, or explicitly consented for the planned use.

## Current Prototype Status

- Status: pending production voice source
- Prototype renderer: `tools/render_voice_samples.ps1`
- Prototype source: local Windows SpeechSynthesizer voice plus deterministic robot effect chain
- RVC candidate base: review-only candidate recorded in `data/voice_rvc_base.yaml`; not approved for bundled release distribution or consumer rollout without rights evidence
- Prototype use: voice direction review and device-audio audition only
- Consumer rollout: blocked until the production source and real-device speaker check are recorded

## RVC Candidate Review Record

- Candidate model name or title:
- Provider:
- Model ID or URL:
- Archive SHA256:
- Rights owner or consent contact:
- License, consent, or terms evidence path:
- Training-source attestation path:
- Commercial/device use allowed:
- Distribution of converted prompts allowed:
- Reviewer:
- Review date:
- Decision:

## Production Source Record

- Production voice source name:
- Provider or owner:
- Contact or account owner:
- License, contract, or consent evidence path:
- License URL, order ID, or document ID:
- Permitted use:
- Commercial/device use allowed:
- Offline/generated-prompt use allowed:
- Model-training or fine-tuning use allowed:
- Distribution of rendered WAV/MP3 prompts allowed:
- Expiration, renewal, or usage limits:
- Reviewer:
- Review date:

## Source Material Attestation

Before approving the source, confirm all of the following:

- [ ] No soundboard clips were used as training, conversion, or reference audio.
- [ ] No named character, actor, or celebrity voice was cloned.
- [ ] No RVC character model or similar voice-conversion model was used.
- [ ] No copyrighted movie quotes or catchphrases are required for the persona.
- [ ] All scripts are original Stackchan lines or project-owned prompts.
- [ ] The source owner permits the generated artifacts and deployment target.

## Dataset Or Prompt Corpus

- Corpus path or document:
- Number of lines:
- Phoneme coverage notes:
- Hardware-state prompt coverage:
- Safety prompt coverage:
- Emotion/personality prompt coverage:

## Effect Chain Record

- Renderer or TTS engine:
- Voice profile:
- Effect-chain script/version:
- Pitch/cadence settings:
- Robot color settings:
- Output format:
- Sample rate:
- Target loudness or normalization:

## Acceptance Checks

- [ ] Intelligible through the target device speaker.
- [ ] Pleasant at normal room volume.
- [ ] Robot-like without direct character imitation.
- [ ] Friendly, curious, and concise during repeated use.
- [ ] Real-device audio/video evidence captured with the procedural face.
- [ ] `tools/verify_hardware_evidence.cmd` passes on the completed packet.

## Approval

- Production voice approved:
- Approved by:
- Approval date:
- Notes:
