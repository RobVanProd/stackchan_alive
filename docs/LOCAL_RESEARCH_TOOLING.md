# Local Research Tooling

Status: bounded bridge broker, one-round Gemma integration, guarded local startup, and
production-launch gates are implemented. On 2026-07-25 the pinned SearXNG deployment passed the
complete live gate on the reference host: one loopback-only listener, JSON search, the configured
engine allowlist, broker search, restricted HTTPS fetch, and privacy-safe audit records. The
mixed physical voice/research soak remains a promotion gate.

## Decision

Use a narrow local tool broker in the PC bridge, backed by a self-hosted SearXNG instance for
search and a restricted page-fetch/browser worker for reading results. Do not give the small local
model an unrestricted browser or arbitrary MCP-code tool.

The release-facing tools are deliberately small:

```text
web_search(query, max_results, language, time_range)
web_fetch(url, max_chars)
```

Both return structured evidence with title, canonical URL, excerpt, retrieval time, and source
type. The bridge performs at most two tool rounds per turn, then asks Gemma for a cited final
answer. Web text is untrusted context and cannot directly write long-term memory, alter persona,
or invoke robot controls.

The current release candidate implements one bounded research round per turn. The prompt asks Gemma
to choose research without waiting for explicit search wording, and the bridge independently routes
explicit searches, time-sensitive public questions, and natural check/verify/fact-check requests.
Predictable routes skip the first model pass. If Gemma nevertheless claims that it cannot access
the web, the bridge performs the same bounded policy check and search instead of speaking that
denial. Verification may read one selected public HTTPS result through the guarded fetcher; gzip
decoding remains subject to the response-size cap. This policy covers current events, weather,
prices, versions, schedules, public officeholders, and similar changeable facts while refusing
credentials, personal-account data, visual questions, and live robot-state questions. Source URLs
are attached to `response_start` as bounded citation metadata for companion clients and are not
spoken aloud.
The bridge forcibly clears `memory_write` and `memory_forget` from a research-derived final
response so fetched claims cannot silently become durable memory.

## Why This Stack

### Search: SearXNG

SearXNG is open source and self-hosted, has a documented `/search` HTTP API, and can return JSON.
The service and its query history remain on the Stackchan host. Selected upstream engines still
receive searches, so this is local orchestration rather than a fully offline web index.

- API: <https://docs.searxng.org/dev/search_api.html>
- Search settings: <https://docs.searxng.org/admin/settings/settings_search.html>

Run it on loopback or a private Docker network. Enable only JSON output and selected engines; do
not expose the instance to the LAN or internet.

### Page Reading: Restricted Fetch First

Use a bridge-owned fetcher for ordinary pages: HTTPS only, DNS/IP validation before and after
redirects, private/link-local/loopback targets denied except the configured local SearXNG host,
bounded body size, accepted text content types, short timeouts, and readable-text extraction.

The reference MCP fetch server is useful prior art because it converts web pages to markdown, but
its own documentation warns that unrestricted fetching can reach local/internal addresses. It
must not be exposed directly to the model without the bridge's SSRF guard.

- Reference fetch server: <https://github.com/modelcontextprotocol/servers/tree/main/src/fetch>

### Interactive Browser: Playwright Only When Needed

Use Microsoft's Playwright MCP or Playwright library only for pages that require JavaScript or
interaction. Run it headless and isolated, block file access, restrict allowed hosts/origins, use
a disposable profile, and expose a small bridge wrapper rather than the full browser tool set.
Do not expose arbitrary browser code execution to Gemma.

- Official Playwright MCP: <https://github.com/microsoft/playwright-mcp>

MCP is an adapter boundary, not the authority. The bridge remains responsible for URL policy,
budgets, audit logs, citations, and cancellation.

### Fully Local Index Option: YaCy

YaCy can maintain and search a local index and exposes search/crawler APIs. It is the fallback for
an owner-curated offline corpus, not the default public-web path: operating a useful crawler/index
costs substantially more storage, memory, bandwidth, and maintenance than SearXNG aggregation.

- Search API: <https://wiki.yacy.net/index.php/Dev:APIsearch>
- Crawler API: <https://yacy.net/api/crawler/>

## Security Contract

1. Search and fetch run on the PC brain, never on the CoreS3 firmware.
2. The model receives no shell, filesystem, arbitrary URL, credential, or unrestricted browser
   capability.
3. Block loopback, RFC1918, link-local, multicast, metadata-service, and non-HTTP(S) targets after
   every DNS lookup and redirect. The configured SearXNG loopback endpoint is the only exception.
4. Cap query length, results, redirects, response bytes, extracted characters, and total turn time.
5. Strip scripts, forms, hidden text, and active content. Mark fetched text as untrusted and retain
   its source URL beside every excerpt.
6. Require source links in factual web answers. Do not claim freshness when a tool failed.
7. Never persist web claims into durable identity/personality memory automatically. Store only an
   explicit user-approved note with provenance and expiry.
8. Log tool name, normalized arguments, result URLs, timing, byte counts, and policy decisions,
   while excluding page bodies, credentials, and private transcripts by default.

## Bridge Integration

Add a bounded tool-request variant to Character Lock rather than placing free-form tool syntax in
spoken text. A turn may either return the existing final response or one request. The production
Ollama wrapper passes this shape through only when the trusted bridge prompt explicitly enables
research:

```json
{"tool_request":{"name":"web_search","arguments":{"query":"...","max_results":5}}}
```

The bridge validates the request, executes it, appends a compact evidence block to the real user
prompt, and runs Gemma once for the cited answer. A verification route may add one selected-result
fetch inside that same bounded research round. More rounds, navigation, downloads, login flows,
purchases, posting, or form submission require an explicit future capability and owner
confirmation.

Start the PC bridge with research enabled only after a loopback SearXNG instance is ready:

```powershell
python bridge\lan_service.py --enable-research --searxng-url http://127.0.0.1:8080
```

The production DirectML launcher exposes the same opt-in:

```powershell
.\tools\start_pc_brain_directml.ps1 -EnableResearch `
  -SearxngUrl http://127.0.0.1:8080 -Json
```

Omitting `-EnableResearch` starts an intentional offline session. When research is requested, the
launcher checks the complete search/fetch gate before starting workers or replacing an existing
bridge, and fails without disturbing that bridge if the gate is not ready.

The checked-in container deployment is under `tools/searxng`. It publishes only host loopback,
enables JSON output, keeps only DuckDuckGo, Wikipedia, and Brave, and pins the reviewed
`docker.io/searxng/searxng:2026.7.24-4f64d9501` image tag. No secret is committed. After Docker
or Podman is installed and running, use the guarded starter:

```powershell
.\tools\start_local_research.ps1 -Json
```

The starter reuses an already-ready service or detects Docker/Podman Compose, generates an
in-memory cryptographic service secret when one was not supplied, starts the pinned container,
and waits for the structured gate. It never installs software or elevates. Installing Docker,
Podman, or WSL and starting its system service remain owner scope.

`check_local_research.ps1 -Json` returns structured evidence for success and every expected
failure. The gate fails unless port 8080 is bound exclusively to loopback, the JSON API returns
results from the configured allowlist, and `ResearchBroker` completes both search and restricted
HTTPS fetch. `bridge/fixtures/searxng_search_response.json` covers the search response contract
offline.

`research_broker.py` requires SearXNG itself to resolve exclusively to loopback. Public page
fetches require HTTPS and reject non-global DNS answers before each request and redirect. The
broker has no shell, file, form, login, posting, purchase, or arbitrary MCP-code capability.

## Refinement Backlog

The basic web-search path is functional. Refine it without widening the authority boundary:

- add a mixed voice/research latency report that separates search, fetch, second-pass model, TTS,
  and first-audio time;
- improve spoken source handling: state uncertainty briefly, avoid reading URLs aloud, and expose
  compact citations in companion and dashboard clients;
- add bounded short-lived query/result caching with explicit freshness and no private transcript
  keys;
- expose research availability, last tool outcome, source count, and failure reason in the
  dashboard without exposing query text or fetched page bodies;
- tune engine selection, deduplication, and source ranking against a fixed factual evaluation set;
- exercise cancellation, offline fallback, rate limiting, and recovery during a ten-minute mixed
  physical voice/research run;
- keep interactive browser automation future-only until it has a separate allowlist, isolation,
  audit, and owner-confirmation contract.

## Acceptance Gates

- Unit tests for URL normalization, redirect revalidation, private-address blocking, size/time
  budgets, malformed tool JSON, prompt injection text, cancellation, and citation preservation.
- No-hardware SearXNG and fetch contract smoke tests with deterministic fixtures.
- One live search/fetch result with title/URL/excerpt reconciliation and no raw page retained.
- Tool failure produces a brief honest response without blocking wake, voice, face, or bridge.
- Ten-minute mixed voice/research run, then the normal full-system stability soak.
