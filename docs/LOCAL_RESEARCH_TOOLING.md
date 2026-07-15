# Local Research Tooling

Status: bounded bridge broker, one-round Gemma integration, and production-launch switches are
implemented. A live local SearXNG deployment and voice/research soak remain pending. As of the
2026-07-12 release audit, no service was listening on the expected loopback port `8080`; do not
describe web research as production-ready until the acceptance gates below pass.

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

The current release candidate implements one tool round per turn. The prompt asks Gemma to choose
research without waiting for explicit search wording, and the bridge independently routes ordinary
time-sensitive public questions when the small model does not request a tool. This deterministic
freshness policy covers current events, weather, prices, versions, schedules, public officeholders,
and similar changeable facts while refusing credentials, personal-account data, and live robot-state
questions. Source URLs are attached to `response_start` as bounded citation metadata for companion
clients and are not spoken aloud.
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
prompt, and reruns Gemma once. A second fetch may be permitted for one selected result. More tool
rounds, navigation, downloads, login flows, purchases, posting, or form submission require an
explicit future capability and owner confirmation.

Start the PC bridge with research enabled only after a loopback SearXNG instance is ready:

```powershell
python bridge\lan_service.py --enable-research --searxng-url http://127.0.0.1:8080
```

The production DirectML launcher exposes the same opt-in without changing its default:

```powershell
.\tools\start_pc_brain_directml.ps1 -EnableResearch `
  -SearxngUrl http://127.0.0.1:8080 -Json
```

Omitting `-EnableResearch` leaves the release voice bridge exactly as qualified. Enabling it does
not install or start SearXNG; the operator must first deploy and bind that service to loopback.

`research_broker.py` requires SearXNG itself to resolve exclusively to loopback. Public page
fetches require HTTPS and reject non-global DNS answers before each request and redirect. The
broker has no shell, file, form, login, posting, purchase, or arbitrary MCP-code capability.

## Acceptance Gates

- Unit tests for URL normalization, redirect revalidation, private-address blocking, size/time
  budgets, malformed tool JSON, prompt injection text, cancellation, and citation preservation.
- No-hardware SearXNG and fetch contract smoke tests with deterministic fixtures.
- One live search/fetch result with title/URL/excerpt reconciliation and no raw page retained.
- Tool failure produces a brief honest response without blocking wake, voice, face, or bridge.
- Ten-minute mixed voice/research run, then the normal full-system stability soak.
