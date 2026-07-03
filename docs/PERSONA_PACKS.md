# Persona Packs: Making the Character OS Swappable and Shareable

Goal: anyone can build their own Stackchan personality, drop it in, and share it — without
touching C++ or Python — while a non-overridable foundation keeps every persona safe,
private, and provenance-clean. Stackchan Spark (the Character Lock) becomes the reference
pack, not a special case.

## Why now

Persona content is currently hardcoded in three unrelated places, and every active phase is
adding more:

- **Firmware C++:** spoken lines live as string literals in `src/persona/SpeechPlanner.cpp`;
  earcon character in `EarconSynth.cpp`; emotion response curves in `EmotionModel.cpp`;
  idle-life timing constants in `IdleLife.cpp`.
- **Bridge Python:** the system prompt is built inline in
  `bridge/reference_bridge.py` (`build_persona_prompt`), duplicating CHARACTER_LOCK.md
  prose by hand.
- **Build tooling:** prompt WAV asset lists are hardcoded tuples in
  `tools/platformio_generate_voice_assets.py`.

Meanwhile `data/voice_persona.yaml`, `data/expressions.yaml`, and `data/commands.yaml`
already hold persona data — but nothing consumes them as a unit. Extracting a pack format
is cheap today and gets more expensive with every hardcoded line P4/P6/P7 adds.

## The two-layer model: foundation vs. persona

The key design decision — this is the "solid foundation" — is a hard split:

**The foundation (engine, non-overridable).** No pack can change:

- servo/motion safety gates, safe-stop behavior, and reduced-motion handling
- privacy and memory hard rules from CHARACTER_LOCK.md §4: the must-not-remember deny
  list, wake-gated capture, "forget that" handling
- the bridge validator's hard caps (a pack may *tighten* the 2-sentence/140-char cap,
  never loosen it) and the closed `mode`/`earcon` vocabulary from `StateMatrix.hpp`
- the no-impersonation boundary and voice-source provenance gate — a pack that ships
  voice assets without provenance fails validation, full stop
- Safety-intent speech behavior: `safety` cues always play, always calm/procedural,
  regardless of persona mood settings

**The persona (data, fully swappable).** Everything that makes Spark *Spark*: adjectives,
speech style, spoken line tables, prompt, expression poses, earcon timbres, emotion
response tuning, idle-life rhythm, circadian schedule, TTS/DSP voice settings.

Enforcement lives in a validator tool, not in convention: an invalid pack is rejected at
load/build time with a specific reason.

## Pack format

```
personas/<pack_id>/
  pack.yaml          # manifest: schema stackchan.persona-pack.v1, id, name, version,
                     # author, license, description, provenance references
  character.yaml     # adjectives, never-rules, speech style (length cap, contraction
                     # policy, avoid-list), phrase patterns, spoken line table keyed by
                     # SpeechIntent (boot/idle/attend/.../safety), mode voice notes
  prompt.md          # bridge system prompt template with slots:
                     # {{character_rules}} {{memory}} {{context_markers}}
  behavior.yaml      # event -> arousal/valence deltas, idle-life params (breathing rate,
                     # micro-expression cadence, gaze wander), circadian schedule
  expressions.yaml   # face pose overrides (existing data/expressions.yaml format)
  earcons.yaml       # per-SpeechEarcon synth parameters for EarconSynth
  voice.yaml         # TTS engine config + Spark-Synth DSP chain params
                     # (existing voice_persona.yaml format) + provenance pointer
  assets/            # optional pre-rendered prompt WAVs + envelope sidecars + checksums
```

One pack drives **both halves** of the system:

- **Firmware path (build-time):** extend the existing `extra_scripts` codegen pattern
  (`platformio_generate_voice_assets.py` already proves it) into
  `tools/generate_persona_assets.py`: reads the pack, emits the SpeechPlanner line table
  header, earcon parameter header, expression pose data, and embedded prompt WAVs.
  Build with `-D STACKCHAN_PERSONA=<pack_id>` (default `spark`). Later, once LittleFS/SD
  asset loading exists, packs can swap without reflashing — but codegen ships value now
  and the pack format is identical either way.
- **Bridge path (load-time):** `lan_service.py`/`reference_bridge.py` take
  `--persona personas/<id>`, build the prompt from `prompt.md` + `character.yaml`, and
  configure the validator (tightened caps, avoid-list lint) and memory policy from the
  pack. Hot-swappable per session.

The firmware `mode`/`earcon` enums stay the stable ABI between packs and the engine —
packs pick *content* for each intent, never new intents. That is what keeps every shared
pack compatible with every firmware build.

## Validation and sharing

`tools/verify_persona_pack.(ps1|cmd)` — same shape as the existing verifier family:

1. Schema check (`stackchan.persona-pack.v1`, required files, versioned).
2. Foundation-invariant check: caps not loosened, deny-list rules intact, safety intent
   lines present and procedural, no impersonation markers.
3. Content lint: every spoken line in `character.yaml` passes the pack's own style rules
   (length, avoid-list) — catches a pack that violates itself.
4. Character harness run: parameterize `bridge/character_harness.py` by pack so its
   validation vocabulary and caps come from the pack + foundation, and replay the
   deterministic transcript against the pack's prompt.
5. Voice provenance gate on any shipped audio (reuses the existing
   `voice_source_provenance` machinery).
6. Checksums over the pack directory.

**Sharing = a zip of the pack folder.** Import runs the verifier before the pack is
usable; the release packager includes the active pack + its verification report so
hardware evidence records exactly which persona was running. No marketplace
infrastructure needed to start — a verified folder format that travels well *is* the MVP
of sharing.

## Migration plan (small PRs, each shippable)

Current implementation status: Spark now exists under `personas/spark` as the active
reference pack, and Glow now exists under `personas/glow` as the quieter second pack that
proves the pack seam is not Spark-specific. The bridge prompt, character harness, firmware
`SpeechPlanner` line table, firmware earcon tone table, firmware face/idle-life/circadian
behavior constants, and red-team dry-run harness load from persona packs. The red-team
gate is corpus/validator-ready, but it still requires a configured real runner before it
can pass as model evidence. Later PRs still need broader codegen coverage for expression
poses and voice assets.

1. **Extract Spark:** create `personas/spark/` from CHARACTER_LOCK.md, `voice_persona.yaml`,
   `expressions.yaml`, and the strings currently in `SpeechPlanner.cpp` /
   `reference_bridge.py`. No behavior change; Spark is now data.
2. **Firmware codegen:** generate the SpeechPlanner line table from the pack; delete the
   hardcoded C++ strings. Native tests keep passing against the generated header.
3. **Bridge loads the pack:** `build_persona_prompt` reads `prompt.md`/`character.yaml`;
   delete the inline prose.
4. **Parameterize the character harness** by pack (foundation rules stay compiled in).
5. **Pack validator tool + CI job** (`verify_persona_pack` on `personas/*` every PR).
6. **Ship a second pack:** done with `personas/glow`, a calm, slower, soft-earcon observer
   persona. Keep using Glow as the regression pack whenever new persona-controlled surface
   area lands. If hardcoded Spark-isms appear, fix them by moving data into the pack, not by
   adding conditionals.
7. Extend codegen coverage as later phases land. Speech lines, earcon params, and the
   face/idle-life/circadian behavior constants are now generated from the pack; expression
   poses and voice assets remain the next pack-native surfaces.

Steps 1-6 can run entirely in parallel with the hardware bring-up track in
[GAP_ANALYSIS.md](GAP_ANALYSIS.md) — this is host/build tooling and pure-logic firmware
refactoring, all covered by the existing test suites.
