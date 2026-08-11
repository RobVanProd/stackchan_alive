# Memory Contract

Status: normative contract and migration target; current implementation remains Memory v4
Baseline: `39b750e6c354d1c4721c70bf20fba98b8ce5c3ec`

## Trust Objective

A false personal memory or unauthorized deletion is more damaging than a missed callback. Memory
therefore optimizes precision, provenance, user control, and deletion durability before recall
volume or conversational smoothness.

This contract does not authorize abrupt replacement of Memory v4. New schema/retrieval work begins
in shadow mode with migrations and side-by-side measurements.

## Current Baseline

Memory v4 already provides bounded records, caps/expiry, same-directory atomic replacement, backup
fallback, v2/v3 migration, deterministic explicit remember/forget routes, privacy filtering,
shared-room suppression, persona-scoped episodes/open loops, and stale-distillation revision
protection.

AUDIT-03 found current contract violations that require a safety repair before Memory v5 work:

- otherwise-valid model-authored writes and forgets can be applied without matching an explicit
  user command;
- generic third-party private details can evade finite-name/possessive filters;
- an unrelated due callback can replace the answer;
- explicit topic recall can return the newest unrelated episode;
- distilled episodes lack entailment, confidence, and source evidence;
- contradiction, structural-corruption, crash-safe reset, and global/persona scope contracts are
  incomplete.

These are source/test findings, not claims that a private live memory contains such data.

## Memory Classes

| Class | Purpose | Authorization | Retention | Persona/scope |
| --- | --- | --- | --- | --- |
| Working memory | Current generation inputs and tool state | Current bounded task/session | Turn/task | Explicit session + persona |
| Session memory | Correction, topic, bounded dialogue continuity | Current conversation controller | Session/cooldown | Session + persona |
| Durable fact | Exact approved preference/fact | Explicit user statement parsed by deterministic host policy | Until expiry/forget/reset | Explicit global/persona/project scope |
| Autobiographical episode | Privacy-filtered shared event | Eligible event plus approved consolidation policy; never arbitrary model text | Expiring/bounded | Persona + participants/context |
| Shared experience | Mutually relevant event/project history | Explicit or policy-approved eligible event with provenance | Expiring/reviewed | User/project/persona |
| Entity record | Alias and non-sensitive relationship between allowed entities | Explicit user authorization or deterministic project structure | Reviewed/expiring | Explicit scope; no biometric identity |
| Open loop | User-approved follow-up/commitment | Explicit request or approval | Due window then expiry | Persona/project/social constraints |

## Sole-Authorizer Rule

The host is the sole authorizer of every memory delta. Authorization has two deliberately separate
sources; model output is neither one:

- A durable user fact, preference, entity alias, project commitment, or any forget/reset requires a
  matching explicit current user instruction derived by deterministic transcript policy.
- A bounded episode or aggregate interaction outcome may be authorized only by an allowlisted,
  versioned deterministic consolidation policy operating on eligible typed source events. It must
  preserve those source IDs, cannot introduce a model-authored fact, and remains shadow-only until
  its privacy, entailment, precision, expiry, and user-control gates are independently passed.

For explicit actions:

1. Deterministic transcript policy derives `authorized_writes` and `authorized_forgets` from the
   current user instruction.
2. Each authorization contains exact normalized key, operation, scope, allowed value/source, and a
   one-turn nonce/revision.
3. Model output may format or refer to an action but cannot add, broaden, wildcard, or substitute
   it.
4. Normalized model actions are cleared unless they exactly match a still-valid host authorization.
5. Global reset/wildcard forget requires an explicit matching reset instruction and deterministic
   confirmation policy; ordinary model output can never originate it.
6. Research/tool output never authorizes memory actions.
7. Applied outcomes are recorded without logging the private value.

Authorization tests must include ordinary-turn injection, malformed action, wildcard deletion,
cross-persona/scope substitution, delayed replay, research output, tool output, generic third-party
fixtures, and policy-derived episode attempts with missing/ineligible/contradictory source events.

## Privacy

Never store secrets, credentials, raw audio/camera, raw transcripts by default, health, finance,
private relationship data, precise location, or third-party private information. A finite list of
names is not an adequate third-party detector. Ambiguous personal content fails closed to
non-persistence and may request explicit clarification without echoing sensitive text.

Shared-room state suppresses personal recall and callbacks. Presence count does not establish
speaker identity or authorization. Diagnostic tests use synthetic fixtures; live memory values are
never printed.

## Retrieval

Retrieval is hybrid and precision-first:

1. deterministic exact key for an explicit request;
2. symbolic entity, scope, project, and temporal candidates;
3. semantic candidates;
4. privacy, persona, provenance, confidence, expiry, and social-setting filters;
5. relevance reranking against the actual request;
6. bounded projection with retrieval reason and evidence reference.

Embedding similarity alone never authorizes a callback. Phrases such as “earlier” or “last time”
do not bypass topic relevance. When no sufficiently relevant record exists, return unknown or ask a
clarifying question.

## Callback and Open-Loop Selection

A due time creates eligibility, not relevance. A callback must match current context or occupy a
non-displacing optional position after the user request is answered. Selection records why it is
relevant now, the original authorization, social/privacy suitability, attempts, cooldown, and why
silence is not better. The runner may not replace a valid answer wholesale merely to mention a
due loop.

## Episodes and Consolidation

An episode stores a bounded structured event summary, participant/context scope, event time,
source event IDs, confidence, privacy decision, and consolidation version. Any model-assisted
distillation is a proposal and must be entailed by eligible source events under deterministic or
tested validation. Hallucinated but policy-shaped text must not become memory.

Consolidation is utility-based and bounded. It may merge compatible evidence while preserving
sources. It cannot convert a prediction/inference to fact or remove a contradiction merely because
one wording is more recent.

## Contradiction and Supersession

Conflicting values are separate records linked by a contradiction set. An explicit correction may
supersede an earlier user-authored fact but retains the old record's ID, source, time, and
supersession reason until expiry/compaction policy permits removal. “Last write wins” without a
trail is forbidden. Near-duplicate episode handling never refreshes an obsolete text while
discarding the correction.

Prompt projection chooses resolved current values only and can express uncertainty when resolution
is incomplete.

## Persistence, Corruption, and Reset

- Validate full structure, caps, checksums/version, and privacy shape before accepting a primary
  file; a parseable dictionary alone is insufficient.
- A structurally invalid primary may fall back to a fully valid backup and records the recovery.
- Writes use same-directory atomic replacement with bounded retry for Windows sharing violations.
- Reset uses a crash-safe tombstone/generation protocol so interruption cannot resurrect a backup.
- Export and inspection exclude secrets/raw media and make scope/provenance/expiry understandable.
- Forget/reset success is verified across primary, backup, journal, index, and derived caches.

## Persona and Shared Scope

Every durable record declares whether it is user-global, persona-private, project-shared, or
session-local. Global preference sharing is never inferred from absence of `persona_id`. Persona
episodes and style remain isolated. A project may be shared only through an explicit typed project
scope with allowed participants; it is not a flat namespace convention.

The product must decide and document which current v4 global facts are intentionally shared before
migration. Ambiguity blocks behavior change.

## User Controls

The user can inspect memory categories, source kind, scope, age, confidence, expiry, contradiction,
and retrieval reason; inspect/export may reveal values only through an authenticated local user
surface designed for that purpose. The user can forget an item/scope, reset all memory, and disable
future durable memory. Routine logs and dashboards never reveal values.

## Shadow Migration and Acceptance

1. Freeze and test v4 authorization/privacy defects independently.
2. Define v5 schema and deterministic v4-to-v5 mapping without destructive conversion.
3. Run v5 journal/retrieval in shadow mode on synthetic trajectories and approved local fixtures.
4. Compare false-memory rate, relevant recall, irrelevant callback rate, provenance accuracy,
   contradiction handling, open-loop precision, persona isolation, restart continuity, and
   deletion durability.
5. Fault-test corrupt primary/backup, partial write/reset, stale revision, and interrupted migration.
6. Obtain independent memory, privacy, character, security, and trajectory review.
7. Promote one bounded consumer only if precision and user-control gates do not regress.

Rollback keeps v4 readable and authoritative until the promoted slice proves safe. No irreversible
schema change, private-value logging, or evidence transfer is permitted.
