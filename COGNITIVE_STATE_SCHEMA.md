# Cognitive State Schema

Status: normative v0 design for Continuity Core shadow mode; no runtime claim
Schema family: `stackchan.continuity`
Baseline: `39b750e6c354d1c4721c70bf20fba98b8ce5c3ec`

## Envelope

Every journal event and state snapshot uses an envelope with these required fields:

| Field | Type | Contract |
| --- | --- | --- |
| `schema` | string | Exact namespaced record kind, such as `stackchan.continuity.event`. |
| `version` | positive integer | Unknown versions fail closed; migrations are explicit. |
| `record_id` | bounded opaque string | Unique locally; contains no private value. |
| `revision` | non-negative integer | Increases for each accepted state transition. |
| `journal_boot_id` | bounded opaque string | Identifies the Continuity Core receipt/reducer boot. |
| `journal_monotonic_ms` | non-negative integer | Authoritative for journal order/deadlines within `journal_boot_id`. |
| `source_clock_domain` | bounded enum/string | Identifies firmware, host, vision worker, or other independent clock owner. |
| `source_boot_id` | bounded opaque string or null | Prevents source-monotonic comparison across that component's restarts. |
| `source_monotonic_ms` | non-negative integer or null | Source-local observation time; never compared across clock domains without an explicit mapping. |
| `wall_time` | RFC 3339 string or null | For human time only; null when unavailable/untrusted. |
| `source` | `SourceRef` | Who asserted this and which authority it has. |
| `confidence` | number in `[0,1]` | Epistemic confidence, never a permission. |
| `freshness` | enum | `current`, `stale`, `expired`, or `unknown`. |
| `privacy_class` | enum | `public`, `local_private`, `user_approved_memory`, or `prohibited`. |
| `evidence_refs` | bounded list | Local opaque references; no raw media, transcript, secret, or fact value in diagnostics. |

All text and list fields have explicit byte/item caps in implementation. Extra fields fail schema
validation unless introduced by a known version.

## Common Types

`SourceRef` contains `kind`, `component`, `source_record_id`, `authority_domain`, and optional
`observed_at`. Valid kinds are `firmware_telemetry`, `host_runtime`, `sanitized_perception`,
`explicit_user_statement`, `authorized_memory`, `tool_result`, `research_result`, `deterministic_inference`,
and `model_proposal`. A `model_proposal` has no authority to rewrite state.

`Uncertain<T>` contains `value: T | null`, `confidence`, `freshness`, `source`, `observed_at`,
`expires_at`, and `contradiction_ids`. `null` means unknown, not false.

`ParticipantRef` contains only a session-scoped or explicitly approved pseudonymous identifier and
role (`user`, `other_person`, `robot`, `unknown`). It never contains biometric identity, inferred
relationship, demographic trait, or third-party private fact.

`Provenance` records source IDs, transformation/reducer version, retrieval reason, confidence,
privacy decision, and any superseded/contradictory record IDs.

## Event Record

An `EventRecord` adds:

- `event_type`: allowlisted enum;
- `participants`: bounded `ParticipantRef` list;
- `coarse_context`: permitted room/social context without identity;
- `related_entities`: bounded opaque entity IDs;
- `appraisal`: optional bounded valence/arousal/novelty/relevance proposal;
- `expected_outcome` and `actual_outcome`: typed status, never free-form private narrative;
- `memory_eligibility`: `ineligible`, `candidate`, or `explicitly_authorized`;
- `retention_class` and `expires_at`;
- payload chosen by `event_type` and schema version.

Initial allowlisted families are conversation phase, explicit user control, authorized memory
outcome, service availability, body telemetry, sanitized presence/room transition, safe touch/IMU
summary, tool/research outcome, project/open-loop transition, prediction outcome, and expression
outcome. Raw microphone, camera, credential, pairing, and arbitrary model-text events are excluded.

## State Snapshot

### `SelfState`

| Field | Type | Authority and persistence |
| --- | --- | --- |
| `mode` | `Uncertain<enum>` | Firmware/host runtime; re-established after restart. |
| `affect_state_ref` | record ID | Points to the single authoritative `AffectState` projection. |
| `body_state_ref` | record ID | Points to the single authoritative `BodyState` projection. |
| `attention_state_ref` | record ID | Points to the current `AttentionState` projection. |
| `quiet_duration_ms` | integer | Monotonic reducer only. |
| `network_state`, `brain_state` | `Uncertain<enum>` | Measured host/runtime health plus freshness. |
| `current_concern` | bounded typed reason or null | Deterministic planner projection; no self-authored need. |
| `conversational_commitment` | task/open-loop ID or null | Conversation controller only. |

### `BodyState`

Contains firmware-authoritative `battery`, `thermal_state`, `motion_available`, `motion_enabled`,
`servo_rail_enabled`, `servo_torque_enabled`, power/thermal/motion suppressions, pickup/IMU/touch/
proximity summaries, and speaker/microphone/vision availability. Every field is `Uncertain<T>` with
its own freshness and source. Commanded state and observed state are different fields. The host or
model cannot fill missing firmware-owned values or infer a hardware root cause.

### `AttentionState`

Contains a coarse target, target kind, selection reason, source observations, confidence, acquired
and expiry times, a `social_context_ref`, and whether addressed-to-robot is known. Person count does
not imply identity or speaker attribution.

### `SocialContext`

This is the single owner of current social setting: `private_one_person`, `shared`, `empty`, or
`unknown`, plus permitted person-count band, addressed-to-robot status, source observations,
confidence, observed/expiry times, and contradictions. Relationship, attention, world, privacy, and
initiative projections reference this record rather than maintaining independent social truth.

### `AffectState`

Contains valence, arousal, dominance/agency, novelty, interaction relevance, decay parameters,
last causal event IDs, and expression confidence. It is presentation-supporting robot state, not a
claim of subjective feeling. Model text cannot set it. Transient error/fear-like state never
persists across restart.

### `RelationshipContext`

Contains persona ID, explicit preferred name, explicitly approved interaction preferences, active
shared-project IDs, authorized open-loop IDs, aggregate welcomed/ignored/rejected initiative
signals, a `social_context_ref`, and initiative permission. Every item retains scope, source,
confidence, and inspection/deletion status. No latent psychological traits are allowed.

### `WorldState`

Contains only sanitized coarse observations: presence transition, person-count band, last known
coarse gaze target, coarse object continuity, lighting band/change, sound direction, robot
relocation signal, and service/sensor availability. Each observation carries source, uncertainty,
expiry, and contradiction state. Identity, ownership, intent, and causality are unknown unless
explicitly established by an allowed source.

### `ConversationalTask`

Contains task ID, mode, user request summary, current stage, bounded tool/research references,
clarification needed, correction context, cancellation state, response/playback phase, deadline,
and terminal outcome. It is session-bounded unless converted to an explicitly authorized shared
project/open loop.

### `SharedProject`

Contains project ID, persona/user scope, explicit title, status, next agreed step, participants as
permitted pseudonyms, expected outcome, last authorized update, provenance, open-loop IDs, and
expiry/review time. Model-generated project state is a proposal only.

### `CuriosityItem`

Contains question/reason, related evidence, expected user value, privacy class, earliest/latest
appropriate time, cooldown, suppression conditions, and status. It cannot open a microphone or
become durable without policy/authorization.

### `OpenLoop`

Contains explicit origin, requested/approved callback, subject entity/project, due window, context
requirements, relevance evidence, persona scope, status, attempts, user response, cooldown, expiry,
and provenance. Earliest due is not sufficient for selection.

### `Prediction`

Contains claim, source, confidence, check condition/window, allowed observation sources, outcome,
contradictions, and expiry. Unchecked predictions may not be restated as facts.

### `InteractionPreferences`

Allowlisted entries include answer length, initiative tolerance, humor frequency, favorite
technical topics, preferred interaction windows, preferred name, persona, and explicitly approved
follow-ups. Entries require explicit statements or transparent aggregate evidence with confidence,
must be inspectable/resettable, and may never include vulnerability or dependence propensity.

## Persistence Classes

| Class | Examples | Restart behavior |
| --- | --- | --- |
| `transient` | presence, current gaze, audio phase, transient affect, errors | Starts unknown; must be observed again |
| `session` | active request, correction context, bounded dialogue state | Ends with session/cooldown/cancellation |
| `expiring` | open loop, prediction, coarse project update | Persists only with explicit expiry/review |
| `durable_authorized` | approved preference/fact/project identity | Persists under `MEMORY_CONTRACT.md` |
| `prohibited` | raw media, secrets, sensitive/third-party private data | Never stored |

## Global Invariants

1. Model output is a proposal and cannot directly mutate any state or memory.
2. Firmware-owned state cannot be overridden or inferred from host intent.
3. Missing, expired, or contradictory evidence cannot be projected as current truth.
4. Every non-null projected claim has source, confidence, freshness, and evidence reference.
5. Privacy eligibility and action authority are independent of confidence.
6. Persona, user, session, and project scopes are explicit; no accidental cross-scope recall.
7. Serialization is bounded, atomic where persistent, migration-versioned, and safe to reset.
8. Shadow-mode records cannot influence production behavior.
