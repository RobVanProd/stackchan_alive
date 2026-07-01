# Stackchan Spark Voice Samples

These are prototype audition samples for the original Stackchan Spark voice direction. They are not a Johnny 5 clone, are not trained from soundboard clips, and do not use RVC character models.

Generated source:
- Local Windows SpeechSynthesizer voice: `Microsoft David Desktop`
- Deterministic robot effect chain: measured source cadence, lowered-pitch resample, high-pass shaping, light ring modulation, subtle bit-depth reduction, soft saturation, and short echo
- Renderer: `tools/render_voice_samples.ps1`

Samples:
- `stackchan_spark_greeting.wav`: Greeting - "Hello. I am Stackchan, and I am awake."
- `stackchan_spark_thinking.wav`: Thinking - "Input received. I am thinking now. Curiosity level rising."
- `stackchan_spark_safety.wav`: Safety - "Small problem found. I can help fix it. Safety first."

Rollout note: these WAVs are for direction review. Before consumer promotion, the voice source still needs a licensed or owned production source and real-device speaker evidence.
