# Stackchan Spark Voice Samples

These are prototype audition samples for the original Stackchan Spark voice direction. They are not a Johnny 5 clone, are not trained from soundboard clips, and do not use RVC character models.

Generated source:
- Source mode: fallback source via `Windows SpeechSynthesizer Microsoft David Desktop`; install eSpeak-NG or pass `-Engine espeak` to use a formant source
- Stackchan Spark Synth v2 DSP: phrase-level micro-prosody, staccato amplitude shaping, lowered-pitch resample, sample-hold texture, high-pass formant emphasis, light ring modulation, comb-filter resonance, subtle bit-depth reduction, soft saturation, short echo, and tiny synthetic chirps
- Tuning: source speech rate `-1` where supported, pitch/cadence resample factor `1.16`, ring modulation `36`/`72` Hz, sample-hold target `14500` Hz
- Renderer: `tools/render_voice_samples.ps1`

Samples:
- `stackchan_spark_greeting.wav`: Greeting - "Hello. I am Stackchan, and I am awake."
- `stackchan_spark_thinking.wav`: Thinking - "Input received. I am thinking now. Curiosity level rising."
- `stackchan_spark_safety.wav`: Safety - "Small problem found. I can help fix it. Safety first."

Audition variants:
- `stackchan_spark_audition_warm_slow_greeting.wav`: warmer, slightly slower review pass for small-speaker intelligibility
- `stackchan_spark_audition_bright_robot_greeting.wav`: brighter, more synthetic review pass with stronger ring/comb edge

Rollout note: these WAVs are for direction review. Before consumer promotion, the voice source still needs a licensed or owned production source and real-device speaker evidence.
