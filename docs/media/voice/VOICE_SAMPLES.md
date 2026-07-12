# Stackchan Spark Voice Samples

These are prototype audition samples for the original Stackchan Spark voice direction. They are not a Johnny 5 clone, are not trained from soundboard clips, and do not use RVC character models.

Generated source:
- Source mode: fallback source via `Windows SpeechSynthesizer Microsoft David Desktop`; install eSpeak-NG or pass `-Engine espeak` to use a formant source
- Stackchan Spark Synth v4 DSP: phrase-level micro-prosody, syllable gating, lowered-pitch resample, speech-envelope electromechanical mask, formant-like resonators, sample-hold texture, light ring modulation, comb-filter resonance, subtle bit-depth reduction, soft saturation, short echo, tiny synthetic chirps, and a lightly blended musical vocoder/harmony layer on the Bright Robot audition
- Tuning: source speech rate `-2` where supported, pitch/cadence resample factor `1.12`, synthetic mask base pitch `104` Hz, mask mix `0.48`, ring modulation `44`/`88` Hz, sample-hold target `11800` Hz, bright vocoder mix `0.105`, bright earcon mix `0.02`
- Renderer: `tools/render_voice_samples.ps1`

Samples:
- `stackchan_spark_greeting.wav`: Greeting - "Hello. I am Stackchan, and I am awake."
- `stackchan_spark_thinking.wav`: Thinking - "Input received. I am thinking now. Curiosity level rising."
- `stackchan_spark_safety.wav`: Safety - "Small problem found. I can help fix it. Safety first."

Audition variants:
- `stackchan_spark_audition_warm_slow_greeting.wav`: warmer, slightly slower review pass for small-speaker intelligibility
- `stackchan_spark_audition_bright_robot_greeting.wav`: brighter synthetic review pass with slightly reduced static, light musical vocoder blend, and phrase-timed chirp/boop accents

Quick MP3 copies:
- `stackchan_spark_audition_bright_robot_greeting.mp3`: browser-friendly copy of the Bright Robot greeting
- `stackchan_spark_thinking.mp3`: browser-friendly copy of the Thinking sample
- The renderer refreshes these MP3 copies from the WAVs with the bundled preview ffmpeg path, so release packages do not carry stale audition audio.

Rollout note: these WAV and MP3 files are quick auditions; the production DirectML RVC files are
published separately under `media/voice/rvc/`.
