# Conversation Harness

## Purpose

The host bridge must preserve a user's intent across terse corrections and
follow-ups without adding a second model call to the common path. Natural
language history remains useful for voice and character, but it is not the
authority for tool arguments, privacy decisions, or commit state.

## Selected Architecture

The bridge uses a hybrid design:

- `ConversationSession` owns the conversation lease, bounded raw history, and
  typed `ConversationHarness` state.
- `ConversationHarness` deterministically tracks a small active tool task,
  currently weather and general public-web research.
- High-confidence repairs rewrite only the named slot and rebuild a standalone
  query. Ambiguous repairs preserve the task and ask for one missing detail.
- The existing Gemma call receives bounded history for natural phrasing and a
  separate trusted task block for resolved host state.
- Tool state and history commit only after the matching playback-complete
  acknowledgement. Barge-in, TTS failure, bridge loss, and session close discard
  pending state.

This follows the strongest parts of published dialogue-state work: explicit
state operations and selective slot overwrite from
[Diable](https://aclanthology.org/2023.findings-acl.615/),
[SOM-DST](https://aclanthology.org/2020.acl-main.53/), and
[TripPy](https://aclanthology.org/2020.sigdial-1.4/), while retaining natural
bounded history. It avoids relying on an LLM as the sole state tracker, a known
weakness in direct comparisons with specialized trackers
([Heck et al.](https://aclanthology.org/2023.sigdial-1.21/)).

Conversational query-rewrite datasets such as
[CANARD](https://aclanthology.org/D19-1605/) and explicit query-rewrite research
([Mo et al.](https://aclanthology.org/2022.emnlp-main.311/)) support rebuilding
self-contained requests. The production path does this deterministically for
known slots rather than paying for another generation. Correction handling is
also informed by work on
[correction grammars](https://aclanthology.org/N04-4016/) and
[human-machine repair](https://aclanthology.org/J06-3004/).

ReAct-style multi-step reasoning remains useful for larger agents
([ReAct](https://react-lm.github.io/)), but it was rejected here because it adds
latency, cancellation boundaries, and tool-injection surface to ordinary robot
turns.

## State and Precedence

Weather place resolution uses this order:

1. Explicit correction in the current turn.
2. Explicit coarse place in the current weather request.
3. Successful committed place in the active conversation lease.
4. Explicitly approved durable weather default.
5. One-slot clarification.

The bridge never infers a place from IP address, Wi-Fi, timezone, robot host,
the words `here` or `current location`, an address, postal code, or coordinates.
An incidental successful search stays session-only. A durable default requires
wording such as:

`Always use West Berlin as my default weather place.`

It can be removed with:

`Forget my weather location.`

Model-authored memory cannot write the reserved weather keys. Loaded values are
revalidated before use.

## Repair Examples

| Active task | Current turn | Operation |
|---|---|---|
| Weather in Boston | `No, West Berlin` | Replace place; search West Berlin |
| Weather in Boston | `I meant Berlin, not Boston` | Replace place; search Berlin |
| Weather in Boston | `No, not Boston` | Ask for replacement place |
| Weather in West Berlin | `What about tomorrow?` | Inherit place; replace time |
| Weather in West Berlin | `And the weekend?` | Inherit place; replace time |
| Failed weather search | `Try that again` | Retry canonical request |
| Any active tool | `Never mind` | Reset tool task |
| Weather in Boston | `Actually, my dad died` | Reset tool task; no network |
| Weather in Boston | `Tell me a joke` | Topic switch; no weather tool |

## Memory Bubbles

Each wake-to-close lease is one bounded conversation bubble. Raw turns stay in
that lease and are not durable memory. On close:

- deterministic, coarse public topics may become a bounded episode;
- research-tainted sessions never enter generative distillation;
- private, location-precise, third-party, or URL-bearing turns are rejected
  before distillation;
- a memory revision and session epoch prevent late background work from
  resurrecting deleted or superseded data.

This is deliberately smaller than open-ended virtual-memory systems such as
[MemGPT](https://research.memgpt.ai/) or reflection pipelines in
[Generative Agents](https://arxiv.org/abs/2304.03442). Those systems are useful
research references, but Stackchan needs explicit provenance, deletion, and
playback commit boundaries before broader consolidation.

## Failure Attribution

The dashboard exposes aggregate-only pipeline state:

- current stage: transcribing, routing, researching, generating, synthesizing,
  awaiting playback, reply window, or failed;
- separate health for model, research, voice, playback, and knowledge handling;
- success/failure counters, consecutive failures, last error code, and elapsed
  time where available;
- typed task domain, status, operation, revision, and changed slot names.

It does not expose transcripts, task values, queries, prompts, result excerpts,
full source URLs, audio, or stable hashes of those values.

## Acceptance Gates

- Zero deterministic false weather routes across the 200-case generated
  topic-switch matrix.
- Correct exact query for explicit place repair, time inheritance, retry, and
  generic search verification.
- No tool route for sensitive detours, cancellation, negative-only corrections,
  inferred/precise location, or ordinary topic switches.
- Wrong-place weather evidence is rejected before task success.
- No incidental place survives session close or serialization.
- Tool-derived turns do not enter generative memory distillation.
- Pending task/history state does not commit after TTS failure, barge-in, stale
  playback acknowledgement, bridge loss, or session close.
- Production logs and dashboard payloads remain value-free.

## Known Boundary

Generic research supports retry, source verification by repeating the canonical
search and fetching the top source, and simple exclusions. Selecting an
arbitrary numbered result across turns requires a bounded session-only result
reference store; it is not inferred from raw text in this version.

Generic SearXNG snippets do not provide a uniform authoritative forecast-valid
timestamp. The bridge validates requested place context and reports empty or
mismatched evidence honestly, but a future typed weather provider should add
timezone and valid-time fields before making stronger freshness claims.
