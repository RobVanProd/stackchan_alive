# Continuity Core

Status: architecture contract for Milestone 2 shadow mode; not implemented by this document
Baseline: `39b750e6c354d1c4721c70bf20fba98b8ce5c3ec`
Schema reference: `COGNITIVE_STATE_SCHEMA.md`

## Objective

The Continuity Core is a versioned host-side reducer and projection layer that makes the reasons
for conversational and expressive decisions typed, inspectable, privacy-filtered, and testable.
It does not replace current memory abruptly and never acquires firmware, actuator, power, OTA,
pairing, camera-authentication, credential, or microphone-wake authority.

Milestone 2 is shadow-only: it observes sanitized inputs, computes proposed state and decisions,
and compares them with the current system. It must not alter prompts, speech, face, voice, gaze,
motion, initiative, persistence, or hardware behavior.

## Data Flow

```text
authoritative telemetry + sanitized perception + conversation/memory/tool events + user controls
                                      |
                              validated event envelope
                                      |
                     bounded privacy-filtered event journal
                                      |
        deterministic reducers and source/confidence/expiry resolution
                                      |
      self + relationship + world + task/project + agenda projections
                                      |
             shadow behavior candidates, validators, and reasons
                                      |
              comparison with the current production decision
                                      |
              metrics only; no production behavior mutation
```

When later milestones permit behavior use, a validated character-locked proposal may emit a typed
expression intent. Deterministic firmware remains the only physical realization authority, and
the observed result returns as a new event rather than being assumed successful.

## Components

### Input adapters

Each adapter maps one existing source into a versioned `EventEnvelope`. It rejects unknown schema
versions, invalid timestamps, oversized fields, unauthorized participant identifiers, private raw
media, secrets, and source claims beyond the adapter's authority.

### Event journal

The journal is bounded and append-oriented. Each event records monotonic and wall-clock time,
source, confidence, coarse permitted participants/context, related entities, expected and actual
outcomes, memory eligibility, expiry, privacy class, and evidence reference. Raw audio, raw camera
frames, transcripts by default, credentials, pairing data, and prohibited sensitive or third-party
facts are never journal payloads.

Journal append does not authorize durable memory. Memory eligibility is only an input to the
separate `MEMORY_CONTRACT.md` authorization process.

### Deterministic reducers

Reducers are pure functions of a prior state and ordered events. They:

- preserve source and evidence links;
- distinguish observation, user statement, retrieved memory, inference, and prediction;
- apply monotonic expiry and bounded confidence decay;
- record contradictions rather than silently overwrite them;
- refuse stale telemetry as current state;
- preserve unknown instead of inventing a default fact;
- cannot call a model, a network service, a hardware endpoint, or a persistence side effect.

### Projections

The core produces bounded projections for self/body/affect, attention/social setting, relationship,
world, active conversational task, shared projects, curiosity, open loops, predictions,
uncertainty, provenance, and interaction preferences. Prompt projections are smaller than stored
state and include why each item was selected.

### Memory v4 and shadow-v5 adapter

Current Memory v4 remains the only production memory authority. A read-only adapter projects its
eligible exact facts, persona-scoped episodes/open loops, expiry, and current retrieval reason into
the shadow schema without modifying v4 or exposing private values. Shadow v5 runs exact/symbolic/
semantic candidate retrieval, privacy/provenance filtering, relevance reranking, contradiction/
supersession, and bounded prompt projection only for comparison metrics; its result never enters
the production prompt in Milestone 2.

Observed conversation, project, and tool outcomes return as typed eligible events. A shadow
consolidation proposal records source event IDs, confidence, privacy/expiry decision, expected
utility, and why it would merge, create, or supersede. It cannot write v4 or v5 production memory.
Promotion requires the authorization, entailment, migration, fault, inspection, reset, and
longitudinal precision gates in `MEMORY_CONTRACT.md`.

### Candidate planner

The planner evaluates `remain_quiet` alongside orient, attend, ask, answer, correct, follow up,
research, express uncertainty, react physically, rest, and end interaction. Every non-silent
candidate contains reason, evidence, expected user value, why-now, why-silence-is-worse, privacy
class, cooldown, suppression conditions, and microphone-window request. A proposal is not an
authorization.

### Consistency and authority validator

Deterministic checks reject proposals that:

- contradict current authoritative state without naming the uncertainty;
- claim a memory, perception, identity, or research result without matching provenance;
- use a stale observation as current;
- displace the user's request with an unrelated callback;
- violate a social-setting, privacy, initiative, wake, persona, or Character Lock gate;
- express dependency, guilt, exclusivity, coercion, or ungrounded affection;
- request authority unavailable to the host/model.

## Authority Matrix

This table is the target ownership contract. It does not assert that current network admission or
firmware HTTP mutation is authenticated. `CURRENT_CAPABILITY_AUDIT.md` and
`INITIAL_RISK_REGISTER.md` record those critical current gaps.

| State or action | Authoritative owner | Core permission |
| --- | --- | --- |
| Display timing, wake, actuator, power, thermal and rail safety | Firmware | Read typed reports; never override |
| Pairing, OTA, credentials, camera authorization | Existing deterministic gates | Read bounded availability only |
| Raw microphone/camera data | Existing wake/camera pipelines | No journal persistence; sanitized summary input only |
| Current bridge/service health | Measured host runtime plus freshness | Project current/stale/unknown; never resurrect stale readiness |
| Durable memory deltas | Host authorization: explicit user command for facts/preferences/projects/forget; separately versioned deterministic eligible-event policy for shadow episodes/aggregates | Model proposes nothing authoritative; record authorized outcome/source only |
| Conversation generation and tools | Existing bounded host brain | Supply validated projection; validate proposal |
| Physical expression | Deterministic firmware coordinators | Emit typed intent only in an approved later milestone |

## Clock, Freshness, and Uncertainty

- Monotonic time governs deadlines, cooldowns, ordering within one boot, and expiry checks.
- Wall-clock time supports user-facing temporal relations only when its source is available and
  plausible.
- A boot/session identifier prevents monotonic timestamps from crossing restarts.
- Every observation has `observed_at`, `expires_at`, source, and confidence.
- Expired state becomes `stale` or `unknown`; it does not remain true through absence of evidence.
- Contradictory equal-authority evidence remains unresolved until a defined tie-break or new
  observation arrives.

## Storage and Privacy

Shadow storage must live under ignored, local output with atomic same-directory replacement,
bounded retention, and no copying of existing private values into fixtures or logs. Diagnostic
views expose counts, types, freshness, provenance shape, and decisions -- not private fact values,
raw transcripts, audio, or frames.

Restart behavior is field-specific. Stable user-approved preference and project identifiers may
be candidates for persistence. Transient affect, errors, current presence, sensor readiness,
active audio state, and unconfirmed body state start unknown and must be re-established.

## Shadow-Mode Comparison

For each eligible production decision, record:

- the sanitized input event IDs and state revision;
- current production decision and available reason;
- shadow candidates, chosen shadow decision, suppressions, and reason;
- whether either side used stale, irrelevant, unsupported, or privacy-ineligible context;
- no raw private content;
- latency and bounded state size.

Shadow output is never fed back into production during Milestone 2. Reviewers label disagreements
before any behavior experiment.

## Failure Behavior

- Invalid or unknown events are rejected and counted; production continues unchanged.
- Corrupt shadow state is quarantined and rebuilt from an eligible bounded journal or starts empty.
- Missing sources yield unknown, not a capability claim.
- Journal or reducer failure disables shadow comparison only.
- A model, vision, network, or robot outage cannot grant broader fallback authority.
- Reset must be crash-safe and must not resurrect a backup after a completed deletion.

## Rollout Gates

1. Schema and pure reducer tests, including rollover/restart/expiry/contradiction cases.
2. Privacy and authority adversarial tests.
3. Migration-free shadow run against synthetic trajectories.
4. Restart, corruption, partial-write, sensor-outage, and brain-outage fault tests.
5. Longitudinal shadow comparison with current production.
6. Independent memory, privacy, character, security, performance, and documentation review.
7. Only then preregister one behavior-consuming experiment; no wholesale switchover.

Acceptance requires bounded storage and latency, zero production behavior changes in shadow mode,
zero authority/privacy regressions, provenance on every projected item, deterministic replay, and
measured disagreement useful enough to justify the next experiment.
