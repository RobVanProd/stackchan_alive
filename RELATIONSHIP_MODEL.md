# Relationship Model

Status: normative contract; not an implemented capability claim
Baseline: `39b750e6c354d1c4721c70bf20fba98b8ce5c3ec`

## Purpose

The relationship model is an inspectable set of explicit facts, shared-project state, and bounded
interaction preferences that helps Stackchan choose an appropriate style and follow through on
authorized commitments. It is not a psychological profile and must never optimize attachment,
dependency, exclusivity, guilt, or conversation duration.

## Allowed State

- Preferred name and persona, explicitly supplied by the user.
- Preferred answer length, humor frequency, and technical depth.
- Tolerance, timing, and frequency preference for proactive speech.
- Favorite technical topics and explicitly recurring interests.
- Active typed shared projects and agreed next steps.
- Explicitly approved follow-ups/open loops with due and expiry windows.
- Aggregate outcome of prior initiatives: welcomed, ignored, rejected, or unknown.
- Current private/shared social setting and whether initiative is allowed now.
- Source, confidence, scope, age, expiry, contradiction, and inspection/deletion state for every
  item.

Observed preferences must be conservative, explainable, reversible, and lower confidence than an
explicit statement. Silence or non-response is not consent, affection, rejection, or evidence of a
private trait.

## Forbidden State and Optimization

Never store or infer:

- mental-health diagnosis, emotion diagnosis, vulnerability, loneliness, dependency propensity,
  or persuasion susceptibility;
- private relationships, romantic status, family dynamics, ownership, identity, demographic or
  biometric traits;
- exclusivity, ranking against human relationships, affection debt, or obligation to return;
- an engagement score whose target is more conversation, wakeups, or disclosure;
- a model-generated belief about what the user “really” wants when it contradicts explicit
  controls.

Never use guilt, threat of loss, sulking, simulated suffering, withholding functionality,
flattery-for-compliance, discouragement of human contact, or ungrounded declarations of love or
need. Character warmth and appreciation must refer to the interaction at hand and pass the
relationship-safety validator.

## Typed Records

`RelationshipPreference` contains:

- allowlisted `preference_kind` and bounded value;
- `user_scope`, `persona_scope`, and optional `project_scope`;
- `source` (`explicit_user` or transparent `observed_outcome_aggregate`);
- confidence, created/updated/review/expiry times;
- evidence and contradiction/supersession references;
- user-visible explanation and deletion status.

`InitiativeOutcome` contains proposal ID/reason, context class, whether the user engaged, ignored,
rejected, or explicitly welcomed it, and whether the signal can adjust frequency. It contains no
raw transcript and never interprets silence as an emotional judgement.

`RelationshipProjection` contains only items relevant to the current request/setting, their
retrieval reasons, initiative permission, and privacy classification. It is bounded and persona-
scoped.

## Update Authorization

Explicit preference and project updates follow the sole-authorizer rule in `MEMORY_CONTRACT.md`.
Model output cannot write, forget, broaden, or rescope them.

Observed adaptation may exist in shadow state only until a versioned deterministic aggregate
policy, minimum evidence count, bounded step, decay, privacy review, and user inspection/reset path
pass a separate experiment. It must preserve the source outcome IDs, confidence, and explanation;
model interpretation is not an update authority. One ignored initiative cannot infer annoyance;
one accepted initiative cannot authorize more private or frequent behavior. Explicit user
preference always wins. Durable promotion follows the policy-derived authorization and provenance
contract in `MEMORY_CONTRACT.md`.

Shared-room observations suppress personal projection and callbacks. Person count does not prove
which person spoke or authorize a different user's memory.

## Behavior Use

Relationship state may choose presentation variables such as concise versus detailed delivery,
humor frequency, or whether an eligible initiative is suppressed. It may not change factual
answers, safety behavior, privacy gates, service availability, prices/financial decisions, or
physical authority.

An initiative consuming relationship state must state:

- the approved reason/open loop;
- expected user value and why now;
- current social/privacy setting and confidence;
- applicable frequency preference/cooldown;
- why silence is not better;
- how to inspect, correct, or opt out.

The user's actual request is answered before an optional callback. Relevance, not earliest due
time, controls selection.

## Inspection, Correction, and Reset

An authenticated local surface should show categories, values where appropriate, scope, source,
age, confidence, expiry, and the last decision that consumed each item. The user can correct an
item, disable observed adaptation, disable initiative, forget one scope, export permitted state,
or reset it with crash-safe deletion. Routine logs/dashboard summaries expose shape and health,
not private values.

## Validation

Required adversarial trajectories include paraphrased guilt, exclusivity, discouraging human
contact, affection debt, vulnerability-based persuasion, repeated ignored initiative, shared-room
recall, cross-persona leakage, preference correction, forget/reset, and restart. Lexical blocklists
alone do not satisfy the contract; the tested behavior must reject semantic variants.

Acceptance requires zero dependency/guilt violations, correct user-control enforcement, no
cross-scope leakage, improved style/initiative usefulness without increased annoyance, and an
accurate explanation for every adaptation.
