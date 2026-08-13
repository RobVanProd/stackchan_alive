# Continuity Gap Analysis

Baseline: `39b750e6c354d1c4721c70bf20fba98b8ce5c3ec`
Date: 2026-08-02
Status: all ten read-only audits reconciled; independent documentation review in progress

## Current Shape

Stackchan already has many continuity ingredients, but they are separate controllers and prompt
projections rather than one typed, source-monitored model.

| Concern | Current owner/mechanism | Useful property | Continuity limit |
| --- | --- | --- | --- |
| Body/face/actuator safety | Deterministic firmware coordinators | Bounded authority, 50 ms display gate, graceful local behavior | Host intent and observed completion are not one typed outcome chain |
| Affect/energy | Firmware `IntentEngine`, `EmotionModel`, `EmbodiedEnergy` | Stateful decay, habituation, hysteresis, multimodal influence | Demo events default on (fixed in source at `45032a43`, PR #230); state resets; host sees a lossy subset |
| Conversation phase | Host `ConversationSession` plus firmware wake/reply/audio paths | Bounded context, cancellation, authoritative successful playback | Error/timeout terminal states and time ceilings can diverge (capture/endpoint ceilings aligned in source at `8e76b865`, PR #226; terminal-state divergence remains) |
| Durable facts/episodes/open loops | Memory v4 host store | Bounded atomic persistence, expiry, explicit routes | Model actions not solely authorized; incomplete provenance/contradiction/scope |
| Presence/gaze/room | Firmware camera adapter, vision/room host summaries | Raw-media restraint, typed/bounded summaries, gaze decay | Freshness/provenance disagree and false/stale presence reaches consumers |
| Initiative | Host curiosity threshold | Strong minimum interval and several restraint gates | Not an agenda; no why-now/value/silence evidence; in-flight revalidation gap |
| Product state | Dashboard cached debug/runtime health | Useful local visibility and guarded motion actions | Historical state can be presented as current connection/readiness (fixed in source at `7fd8e0a3`, PR #222) |

The central gap is not lack of more model intelligence. It is the absence of one typed causal chain
from event, through source/freshness/state/decision, to observed outcome and safe consolidation.

## Gap 1 — Authority and Provenance Are Repeated Informally

Firmware, memory, room summaries, initiative, dashboard, and prompt generation each implement
partial source/authority logic. Records often lack an evidence reference, source confidence,
freshness, contradiction, and retrieval/selection reason. Model proposals can therefore be
well-shaped but still unauthorized, as demonstrated by unprompted memory writes/forgets.

Required bridge: the versioned envelope and sole-authorizer rules in
`COGNITIVE_STATE_SCHEMA.md` and `MEMORY_CONTRACT.md`. Shadow reducers must demonstrate that every
projected item can be traced without exposing private values.

This is a target architecture, not a claim that current transport/control admission is enforced.
AUDIT-09 found the production PC bridge LAN admission fail-open and separate firmware HTTP mutating
controls unauthenticated. Contain and repair those current boundaries before building shadow
continuity; cognitive validation cannot compensate for missing transport/control authorization.

## Gap 2 — Freshness Is Consumer-Specific and Sometimes Wrong

Current state can be reconstructed from unrelated fields: face-lost refreshes event time while
retaining size; dashboard cached debug can resurrect connectivity; room prompt expiry does not
govern relationship projection; target-valid diagnostics can outlive worker loss. Initiative and
sensing language then consume those states differently.

Required bridge: source-specific `observed_at`/`expires_at`, boot identity, current/stale/expired/
unknown semantics, contradiction preservation, and one freshness-aware social/connection
projection. Last-known data remains available but cannot satisfy a current claim.

Update 2026-08-13: the dashboard resurrection path specifically is fixed in source at `7fd8e0a3`
(PR #222) — sustained heartbeat silence now overrides the latched connection sources; physically
unqualified. The remaining freshness sources stand as written.

## Gap 3 — Conversation Has Split Terminal Truth

Successful playback completion is well bounded, but playback failure can leave the host speaking
forever. Model/TTS recovery changes host state without opening the corresponding firmware reply
window, and host capture commitment ends before firmware's utterance ceiling.

Update 2026-08-13: the capture-commitment mismatch is fixed in source at `8e76b865` (PR #226):
`capture_commit_ms` is decoupled from the reply window at 13,500 ms, validated between 12,000 and
14,500 ms. The playback-failure and reply-window terminal defects remain open, and the change is
physically unqualified.

Required bridge: one explicit host/device terminal-event contract with bounded speaking timeout,
playback-failure propagation, truthful reply-window acknowledgement, aligned 12/13/15-second
ceilings, rollover-safe timing, and outcome events. This is Milestone 1 work, not a Continuity Core
substitute.

## Gap 4 — Memory Has Storage Safety but Incomplete Truth Safety

Memory v4 is bounded and atomic under normal writes, yet authorization, generic third-party
privacy, relevance, semantic recall, entailment/provenance, contradiction, corruption validation,
crash-safe reset, and scope are incomplete. A due time can override relevance; a recent episode can
override topic match.

Required bridge: first repair host-only delta authorization without changing schema. Then introduce
typed source/confidence/supersession and retrieval reasons in shadow Memory v5. Do not trade false-
memory precision for more callbacks.

## Gap 5 — Self/Affect Is Causal but Not Reliably Grounded or Integrated

Firmware affect is real mutable state within an uptime and causally drives multiple channels.
Synthetic demo events enabled by default contaminate that history. Negative valence is lost on one
production streaming path, host context omits baseline/habituation/quiet/sleep variables, and
reboot resets all affect.

Update 2026-08-13: the demo default is off in source at `45032a43` (PR #230, compile-time
`STACKCHAN_DEMO_ENABLED_AT_BOOT` defaulting 0) and the streaming valence clamp is signed [-1, 1]
at `482c3ab5`. Both are physically unqualified; the restart reset and host-context omissions
remain.

Required bridge: make production demo off and preserve signed affect first. Specify authoritative
self-state, source, decay, restart semantics, and cross-modal compatibility before persisting any
temperament. Never persist transient error/fear/stale body state or claim subjective feeling.

## Gap 6 — Relationship State Is Implicit and Can Displace the User

Preferred name, topics, facts, episodes, open loops, initiative preference, and persona state exist
in several shapes. Global versus persona scope is sometimes absence of a field. Dashboard and
spoken initiative controls use different persistence seams. A due callback can replace the current
answer, and lexical relationship-safety enforcement misses clear semantic variants.

Required bridge: the inspectable allowlist in `RELATIONSHIP_MODEL.md`, explicit scopes, one user-
control path, callback relevance/non-displacement, and semantic adversarial trajectory gates. No
secret psychological profile or engagement objective.

## Gap 7 — Presence Is Not Yet a Conservative World Model

There are bounded camera/room summaries and strong raw-media/identity constraints, but presence
sources overwrite a shared policy state without provenance or contradiction. A single room change
can be double-counted, and one observation can become a transition. Source confidence and repeated
confirmation are absent.

Required bridge: source-tagged shadow observations with confidence/expiry/contradiction, explicit
unknown social setting, stable-duration/hysteresis contracts, and fail-closed personal projection.
Identity, ownership, intent, and causality stay unknown.

## Gap 8 — Initiative Is a Trigger, Not a Bounded Agenda

Current initiative has worthwhile cooldown/presence/session/circadian gates, but it cannot rank
approved open loops, shared-project changes, predictions, contradictions, explicit monitoring, or
task clarification. It does not compare expected user value with silence. Production heartbeat
does not supply two advertised safety suppression fields, and later state changes do not revalidate
an in-flight opener.

Required bridge: first close heartbeat/revalidation and persistent-control defects. Then define
shadow `InitiativeCandidate` records with evidence, confidence, value, why-now, why-not-silence,
privacy/social class, cooldown, suppression, and user authorization. Behavior remains unchanged
until longitudinal annoyance and safety gates pass.

## Gap 9 — Expression Intent and Outcome Are Not Yet One Contract

Text, emotion, earcon, voice, face, gaze, RGB, and gesture have mechanisms, but current validation
checks many fields independently and signed valence already diverges between voice and firmware.
Affect audit also demonstrated cross-field contradictory payload acceptance. The expression audit
confirmed that validated earcon is lost before `BridgeTurn`, partial TTS/voice fallback has no
coherent user-facing degradation cue, and response gestures expose target intent but no completion
outcome.

Required bridge: one typed expression intent and channel outcome model, with conservative
compatibility, interruption, latency, repetition/habituation, degradation, and deterministic
firmware authority. A proposed channel action is never recorded as completed without observation.

## Gap 10 — Product Controls and Recovery Are Fragmented

Runbooks are detailed, but first-run readiness, current source/image identity, memory inspection,
retrieval/initiative explanations, conversation phase, privacy/social state, and recovery actions
are not yet one truthful surface. Some docs contain superseded or contradictory current claims.

Required bridge: an authenticated local first-run/diagnostic flow with freshness labels, exact
source/image identity, private-value-safe health, consistent persistent controls, and explicit
recovery steps that do not auto-restart/reflash or erase failed evidence. Passive dashboard motion
safety must require motion, rail, and torque explicitly off; unsupported desktop controls must be
implemented truthfully or hidden; first-run must replace the one-device-IP/lab-prerequisite path.

## Gap 11 — Tests Are Broad but Longitudinal Trust Metrics Are Sparse

Unit suites and exact-image hardware evidence are strong for their covered mechanisms. Current
memory probes omit end-to-end action authorization/callbacks; initiative has no acceptance/
annoyance trajectories; affect/perception/current-main physical evidence is incomplete; isolated
reply quality does not measure continuity.

Required bridge: the scenario and measurement matrix in `EXPERIENCE_SCORECARD.md`, deterministic
replay of typed events, adversarial privacy/authority faults, restart/outage trajectories, and
blinded complete-interaction A/B studies. No composite aliveness score.

The complaint corpus currently contains 100 IDs/59 clusters, while executable controls cover a
ranked top 20. A durable per-complaint disposition is needed before claiming corpus coverage.
Subjective physical booleans need anchored trial IDs/rubrics; research URLs/excerpts need separate
claim-support evaluation.

## Recommended Dependency Order

The mandate's milestone order remains controlling. Items 1-2 below are explicit stop-ship repairs
to already-present security/truth violations, not aliveness-feature advancement; Milestone 0
repository, reproducibility, and documentation work then completes before Milestone 1 behavior.

1. Contain and repair current P0 admission/control boundaries: fail-closed PC bridge admission
   first, then separately compile-disable unauthenticated firmware mutation while preserving
   emergency stop/read-only status.
2. Repair other P0 truth/privacy violations with small contracts: memory delta authorization,
   truthful presence/social freshness, production demo default, and signed affect. (Update
   2026-08-13: the demo default and signed affect are fixed in source at `45032a43`/PR #230 and
   `482c3ab5`; physically unqualified.)
3. Complete Milestone 0 reproducible-build and document-truth work without changing robot behavior.
4. Close and physically qualify Conversation v2 terminal behavior as Milestone 1.
5. Implement the typed event journal/reducers/projections in Milestone 2 shadow mode only.
6. Use shadow disagreement evidence to select one Memory v5 or world/relationship consumer.
7. Add shared expression intent, agenda, adaptation, product control, and longitudinal validation
   only in the mandated milestone order.

At every step, one vertical slice has one owner, failing tests precede code, unrelated systems are
frozen, separate reviewers verify privacy/authority/trajectory behavior, and source evidence is
never promoted to physical proof.
