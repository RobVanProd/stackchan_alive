# Creating A Stackchan Persona

Persona packs are the shareable Character OS layer for Stackchan: Alive. A pack changes
style, lines, prompt rules, face tuning, earcons, behavior rhythm, and voice metadata
without editing C++ or Python.

The intended workflow is copy-edit-validate-build.

Keep the creator path simple:

```powershell
.\tools\create_persona_pack.cmd nova -Name "Stackchan Nova" -Author "Your Name"
```

That command copies `personas/spark` to `personas/nova`, updates the pack identity fields,
and immediately validates the new pack.

## Edit

Start with these files:

- `personas/nova/character.yaml`: display name, traits, prompt rules, LLM speech limits,
  forbidden terms, memory policy, and spoken-line table.
- `personas/nova/prompt.md`: the bridge system prompt wrapper. Keep
  `{{character_rules}}`, `{{memory}}`, and `{{context_markers}}`.
- `personas/nova/behavior.yaml`: idle rhythm, circadian windows, and emotional response
  gains.
- `personas/nova/expressions.yaml`: face pose and gesture tuning.
- `personas/nova/earcons.yaml`: procedural sound cue tone parameters.
- `personas/nova/voice.yaml`: voice/DSP target, packaged prompt metadata, and voice
  provenance notes.

Do not loosen the foundation rules. The validator rejects wider response caps, unsafe
memory prefixes, missing safety lines, clone markers, bad prompt slots, and missing
packaged prompts.

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
