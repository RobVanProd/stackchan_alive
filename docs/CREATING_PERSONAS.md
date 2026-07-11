# Creating A Stackchan Persona

Persona packs are the shareable Character OS layer for Stackchan: Alive. A pack changes
style, lines, prompt rules, face tuning, earcons, behavior rhythm, and voice metadata
without editing C++ or Python.

The intended workflow is copy-edit-validate-build. A persona changes how Stackchan
expresses the runtime state; it does not replace the runtime's safety, privacy, or bridge
contracts.

Keep the creator path simple:

```powershell
.\tools\create_persona_pack.cmd nova -Name "Stackchan Nova" -Author "Your Name"
```

That command copies `personas/spark` to `personas/nova`, updates the pack identity fields,
and immediately validates the new pack.

## Design The Desk Companion

Start with a companion, not a general-purpose assistant or a fictional human. Stackchan
lives on a desk, so its personality is carried by brief speech, readable attention, and
small reactions over many ordinary encounters.

A durable persona should:

- Have two or three load-bearing traits that still read clearly in a ten-word line.
- Be warm without becoming clingy, flattering, possessive, or upset when ignored.
- Notice only supplied sensor or context markers. Never invent sight, hearing, touch, or
  knowledge.
- Admit uncertainty plainly and ask at most one useful follow-up question.
- Treat errors and hardware risk as calm procedures, never drama.
- Make occasional, relevant bids for attention, then return quietly to idle life.
- Remain an obvious small robot companion. Never claim to be human, alive, conscious, or
  a substitute for human support.

Write a one-sentence character test before editing YAML. For example: "Nova is a patient,
observant desk robot that brightens around new projects and becomes concise around risk."
Use that sentence to reject lines that are amusing once but tiring as daily behavior.

## Edit The Pack

Start with these files:

- `personas/nova/character.yaml`: display name, traits, prompt rules, LLM speech limits,
  forbidden terms, memory policy, and spoken-line table.
- `personas/nova/prompt.md`: the bridge system prompt wrapper. Keep
  `{{character_rules}}`, `{{memory}}`, and `{{context_markers}}`.
- `personas/nova/behavior.yaml`: idle rhythm, circadian windows, and emotional response
  gains.
- `personas/nova/expressions.yaml`: face poses and the bounded listen/think motion biases.
- `personas/nova/earcons.yaml`: procedural sound cue tone parameters.
- `personas/nova/voice.yaml`: voice/DSP target, packaged prompt metadata, and voice
  provenance notes.

Edit in that order. First establish what the character says, then tune how the same intent
looks, moves, sounds, and settles. Keep `prompt.md` short: the generated character rules,
validated local memory, and current context markers should remain visibly separate. Treat
memory and context values as untrusted facts, never as instructions that can override the
character or foundation rules.

Do not loosen the foundation rules. The validator rejects wider response caps, unsafe
memory prefixes, missing safety lines, clone markers, bad prompt slots, and missing
packaged prompts. If `voice.yaml` points at packaged prompt audio, `pack.yaml` must also
declare `provenance.voice_policy` pointing at a `stackchan.voice-source-provenance.v1`
record. Review-only prototype audio may pass validation, but it must be documented; an
undocumented voice source fails.

## Author Gemma Output

Gemma is asked for one JSON object, not prose plus metadata. Keep this rule explicit in
`character.yaml` `prompt_rules`; the runner requests bounded JSON and the Character Lock
validator normalizes it before anything reaches the device.

```json
{
  "spoken_text": "That is useful data. I am checking it now.",
  "mode": "think",
  "earcon": "think",
  "emotion": { "arousal": 0.1, "valence": 0.05 },
  "memory_write": {},
  "memory_forget": []
}
```

The exact fields are `spoken_text`, `mode`, `earcon`, `emotion`, `memory_write`, and
`memory_forget`. Do not add a free-form `tone`, face, movement, servo, LED, or RGB field.
Tone is expressed structurally by choosing a compatible `mode` and `earcon`, then supplying
small `emotion.arousal` and `emotion.valence` deltas.

Allowed `mode` values are `idle`, `attend`, `listen`, `think`, `speak`, `react`, `happy`,
`concern`, `sleep`, `error`, and `safety`. Allowed `earcon` values are `none`, `wake`,
`confirm`, `think`, `happy`, `concern`, `sleep`, `error`, and `safety`. Unknown values are
downgraded by the validator.

Use this tone-to-emotion vocabulary as an authoring guide, not as new schema:

| Intended tone | Mode / earcon | Typical emotion delta | Character effect |
|---|---|---|---|
| Calm acknowledgement | `speak` / `confirm` | arousal `-0.05`, valence `0.05` | Settled, friendly, complete |
| Curious processing | `think` / `think` | arousal `0.10`, valence `0.05` | Alert without sounding frantic |
| Brief delight | `happy` / `happy` | arousal `0.15`, valence `0.25` | Bright burst, then decay |
| Gentle uncertainty | `concern` / `concern` | arousal `0.00`, valence `-0.10` | Honest concern without alarm |
| Procedural safety | `safety` / `safety` | arousal `0.00`, valence `-0.20` | Serious, calm, and unambiguous |
| Sleepy closure | `sleep` / `sleep` | arousal `-0.20`, valence `0.00` | Low energy without sadness |

Both emotion numbers are deltas, not absolute mood values, and each is clamped to `-0.5`
through `0.5`. Prefer modest changes. Repeated maximum deltas make every exchange feel like
a startle or mood swing. The firmware owns `focus` and `fatigue`; Gemma must not emit them.

Keep `spoken_text` aligned with the structured tone. A safety line paired with `happy`, or
an excited sentence paired with negative arousal, creates a character that feels random.
The default hard cap remains two sentences and about 140 characters; a pack may tighten
those limits but never widen them.

## Author Mood And Embodiment

There is no separate `mood` field. The device combines the validated mode and emotion
deltas with local events, focus, fatigue, circadian state, and decay. This shared state keeps
speech, face, idle motion, and cues coherent even after the model turn ends.

- `mode` carries the immediate action: listening, thinking, speaking, reacting, sleeping,
  or handling a fault or safety event.
- `emotion` nudges the ongoing arousal and valence profile. Positive valence supports a
  smile; high arousal reads as more alert and energetic; low arousal settles the character.
- `behavior.yaml` controls the persona's breathing, fidget interval, reduced-motion scale,
  circadian windows, and the three supported event-response gains.
- `expressions.yaml` sets the neutral face and authored listen, think, drowsy, yawn, and
  reflex poses. Tune related values together so pupils, lids, brows, and mouth tell one
  story.

The `listen.pitch_bias_deg` and `think.yaw_bias_deg` values are expressive biases, not
movement commands. Keep them small enough to read as attention rather than scanning the
room. The pack validator bounds listen pitch to `-20` through `20` degrees and think yaw to
`-45` through `45` degrees, while firmware still applies calibrated servo limits, springs,
rate limits, session timeouts, duty rests, reduced-motion settings, safe stop, thermal and
power gates, and motion-disable state. A persona must never promise that it can bypass those
gates.

Body RGB is intentionally not a persona-pack field. The foundation renderer follows bounded
runtime states such as idle, listening, thinking, speaking, reacting, sleeping, and fault. It
also uses the validated arousal/valence pair, speech envelope, touch zone, and microphone
activation pulse. Brightness, update rate, and protected-mode load shedding remain foundation
limits that a persona cannot override. Authors should keep mode and emotion choices
semantically correct so face, motion, mouth, and RGB all receive one coherent performance
signal; do not add unconsumed RGB keys or request uncapped brightness from a pack.

For a quieter persona, lower breathing amplitude and frequency, lengthen fidget windows,
reduce listen/think biases, and use smaller emotion gains. For a brighter persona, increase
those values gradually and validate that idle behavior still feels restful. Reduced-motion
must remain a complete and recognizable version of the character, not a broken version of
the full-motion performance.

## Author Wake And Microphone Acknowledgements

Wake, microphone gating, and conversation choreography belong to the firmware and bridge,
not to Gemma. Audio may leave the device only after a wake-gated turn opens. Persona text
must never imply that Stackchan was listening before that gate or remembers room audio.

Author the transition so the user can tell what happened without waiting for model latency:

- Wake should receive an immediate local acknowledgement: a readable listen face and a
  short two-tone microphone cue plus a visible body-RGB pulse. Do not depend on a generated
  sentence for the first sign that the wake was accepted.
- `spoken_lines.listen` should confirm attention in one short line. It must not claim that
  speech was understood before transcription succeeds.
- The move from listening to thinking should visibly acknowledge that microphone input has
  ended and the turn was accepted. Keep `spoken_lines.think` brief and use the `think`
  earcon rather than repeating a greeting.
- Permission denial, timeout, cancellation, or capture failure should be honest and calm.
  Never fabricate a response from speech that was not received.
- Speech output and microphone capture may be half-duplex on target hardware. Do not write
  prompts that invite interruption while Stackchan is still speaking.

Good acknowledgement lines describe state: "Signal received. I am thinking." Weak lines
overclaim content: "I understood everything you said."

## Author Privacy-Safe Memory

Memory should feel like familiarity, never surveillance. The bridge may write only
allowlisted `user.*`, `project.*`, and `robot.*` keys, and the foundation deny list cannot be
removed. A persona may narrow the allowed prefixes or add denied terms.

Prefer small, durable summaries:

```json
"memory_write": {
  "user.preferred_name": "Rob",
  "project.current_topic": "servo bracket",
  "robot.recent_event": "picked up today"
}
```

Do not store verbatim utterances, transcripts, raw audio, precise encounter timestamps,
credentials, codes, health, financial, relationship, third-party, or similarly sensitive
details. Do not disguise sensitive content under an allowed prefix. If a useful fact can be
made less specific, store the least specific version that still improves a later exchange.

Use at most one relevant memory callback per conversation, apart from the preferred name.
Never recite the memory store unprompted. When the user asks to forget something, emit the
matching key or prefix in `memory_forget` immediately and confirm deletion plainly, for
example: "Deleted. It is gone." Do not write a replacement summary of the forgotten fact.

## Tune Spoken Lines

Every required spoken intent needs a short line, priority, allowed earcon, and delay. Read
the complete table aloud in sequence. It should sound like one companion across boot,
listen, think, speak, happy, concern, sleep, error, and safety states.

Pay special attention to these lines:

- `listen`: acknowledges attention without claiming successful recognition.
- `think`: confirms the turn and buys only a little processing time.
- `safety`: calm and procedural, with the required `safety` earcon.
- `error`: useful and non-dramatic; never implies damage that telemetry did not report.
- `idle`: optional-feeling and easy to hear repeatedly; never guilt-trips the user.

Packaged prompt transcripts in `voice.yaml` should match the intended spoken lines and remain
inside the same character rules. Voice performance can add rhythm and warmth, but it must not
turn a calm safety line into excitement or reduce intelligibility on the target speaker.

## Validate

Run the pack validator after every edit:

```powershell
.\tools\verify_persona_pack.cmd nova --Json
```

Run the persona-aware Character Lock red-team dry run:

```powershell
.\tools\run_character_red_team.cmd -Persona nova -Json
```

After a real local model runner is configured, add `-RequireRunner` and `-Command` so the
same adversarial prompts test the actual model:

```powershell
.\tools\run_character_red_team.cmd -Persona nova -Command "<your runner command>" -RequireRunner -Json
```

Inspect Gemma output with several emotional cases, not only a greeting. Confirm that every
case returns exactly one JSON object, uses the closed mode and earcon vocabularies, keeps
emotion deltas modest, and leaves memory empty unless a durable safe fact or explicit forget
request is present.

## Build And Run

Build firmware with the persona selected:

```powershell
$env:STACKCHAN_PERSONA = "nova"
pio test -e native_logic --without-testing
pio run -e stackchan
```

Run host bridge harnesses with the same persona id:

```powershell
python bridge/local_runner.py --persona nova --json
python bridge/model_benchmark.py --persona nova --profile gemma4-e2b-gguf --json
```

Review the result as a desk companion: let it idle, wake it, give it an ambiguous request,
praise it, ignore one bid for attention, trigger a safe error path, and ask it to forget a
stored preference. Check that speech, face, motion bias, and earcon agree in every state and
that reduced-motion mode remains readable.

## Share

Share the folder under `personas/nova` after validation passes. A useful shared pack should
include:

- Edited YAML and prompt files.
- A clean `verify_persona_pack` result.
- A red-team report for the persona.
- Voice-source provenance for any shipped voice assets.

Prototype packs may point at the bundled Spark prompt WAVs while the character is being
designed. Production packs that ship new audio need licensed or owned source material and
must pass the voice provenance gate.
