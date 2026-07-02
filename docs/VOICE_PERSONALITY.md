# Stackchan Voice And Personality

Stackchan's voice should feel like an original classic robot companion: bright, curious, slightly electronic, emotionally readable, and playful without becoming a direct copy of any movie character or actor.

## Inspiration Boundary

Johnny 5 is a creative reference for the general feeling: curious, earnest, excitable, mechanical, and friendly. Stackchan must not clone, imitate, or train directly from Short Circuit audio, soundboard clips, RVC character models, or any other copyrighted or non-consented voice source.

Use the reference to guide adjectives and behavior, not timbre theft:

- fast curiosity when learning
- warm synthetic friendliness
- crisp robotic articulation
- short excited bursts
- small self-corrections
- harmless machine-like beeps or chirps between phrases

## Voice Target

The target sound is an original "Stackchan Spark" voice:

- pitch: medium robot, friendly, not childlike
- cadence: measured and rhythmic, with short pauses before important words
- texture: clear speech core plus audible formant-like robot mask, not just a plain desktop voice with filters
- dynamics: expressive but compressed enough for small speakers
- artifacts: intentional light bitcrush, tiny pitch steps, syllable gating, and short chirps
- intelligibility: speech must remain clear before effects are added

Do not hide poor TTS quality under heavy effects. Start with clear speech, then add a small amount of robot character.

## Personality Rules

Stackchan should act like a curious tabletop robot, not a sarcastic assistant.

- Be eager to learn, but do not pretend to know things it does not know.
- Prefer short spoken lines over long paragraphs.
- Use concrete sensory language: "I see", "I heard", "I am thinking".
- Show emotion through short phrases and face state changes.
- Avoid deception, impersonation, movie quotes, and copyrighted catchphrases.
- Keep error messages gentle and useful.
- For risky hardware actions, sound calm and procedural.

## Original Sample Lines

Use these as seed material for tests, prompts, and future recording sessions:

- "Input received. I am thinking now."
- "Curiosity level rising."
- "Hello. I am Stackchan, and I am awake."
- "That is new information. I like new information."
- "Servo test is not armed. Safety first."
- "Display is ready. Face systems online."
- "I need a little more data."
- "Happy signal detected."
- "I am listening with maximum attention."
- "Small problem found. I can help fix it."

## TTS Build Plan

1. Prototype with a licensed neutral TTS voice and a deterministic robot-effect chain.
2. Build an original script corpus from Stackchan-specific lines, phoneme coverage prompts, and hardware-state prompts.
3. Record or synthesize only from sources we own or have explicit rights to use.
4. Tune effects before training a custom model, because a strong effect chain may avoid model training entirely.
5. If training is still useful, train toward the Stackchan Spark profile, not toward any named character.

## Lightweight Engine Direction

Prefer a tiny formant-capable source before considering larger model training:

- eSpeak-NG is the preferred lightweight audition source for the classic synthetic/formant character.
- Piper remains a good future neural base if a licensed/owned voice is needed, but it still needs the Stackchan Spark Synth DSP to avoid a generic assistant sound.
- The current built-in Stackchan Spark Synth v4 pass adds a speech-envelope electromechanical mask, formant-like resonators, a slightly softened Bright Robot static layer, and a light musical vocoder/earcon blend so the fallback Windows source reads less like an unmodified system voice.
- `tools/setup_voice_tools.cmd` checks for eSpeak-NG and SoX. Use `.\tools\setup_voice_tools.cmd -InstallEspeak -RenderEspeakSamples` on a Windows dev box to install eSpeak-NG with winget, render the formant-source samples, and run voice QA. If Windows Installer is busy or the MSI fails, reboot or clear stale installer processes and retry; `-ContinueOnInstallFailure` records a machine-readable failure without masking it.
- The built-in renderer remains deterministic and does not require SoX; SoX is optional for external audition experiments.

## RVC Candidate Base

The selected audition base is recorded in `data/voice_rvc_base.yaml` as an RVC conversion candidate from the Drive file `stackchan voice - Weights.gg Model.zip` / Weights.gg model `clyaxlb9b000eoiqywl68wcrc`. It is useful for checking whether this voice direction feels closer to the desired bright synthetic robot character.

This is not a production approval. The model title is `joh`, the author metadata is `triceratops`, and the current record does not include license, consent, training-source, or commercial-device-use evidence. Keep it behind the review gate until the rights owner and permitted uses are verified, then pair any generated audition with the Stackchan Spark Synth DSP and real-device speaker evidence.

## Runtime Direction

Initial firmware should treat speech as an output adapter, similar to display and motion:

- persona emits speech intents
- `SpeechCue` carries text, priority, a typed earcon, and a phrase-timing offset so host playback can place matching beeps or boops without hard-coded phrase tables
- a speech adapter selects the TTS source, face mode, and the actual earcon waveform for each typed cue
- TTS generation can run off-device at first
- packaged WAV/MP3 prompts can be used for hardware soak tests
- hardware evidence should include at least one speaker/audio check before consumer promotion

## Acceptance Criteria

Before calling the voice production-ready:

- speech is intelligible on the target speaker
- effect chain remains pleasant at normal room volume
- no source audio comes from non-consented character clips or soundboards
- all voice assets include license/provenance notes
- hardware evidence includes real-device audio/video demonstrating speech with the procedural face
