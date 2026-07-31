"""Typed, session-only dialogue state for conversational tool continuity."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Mapping

MAX_LOCATION_CHARS = 64
MAX_LOCATION_WORDS = 7

_WEATHER_SIGNAL = re.compile(
    r"\b(?:weather|forecast|temperature|rain|snow|wind|humidity)\b",
    re.IGNORECASE,
)
_NON_WEATHER_WEATHER_TEXT = re.compile(
    r"\b(?:joke|story|song|poem|history|science|system|station|app|code|"
    r"weatherproof|weathering|climate|systems?)\b",
    re.IGNORECASE,
)
_WEATHER_LOCATION = re.compile(
    r"\b(?:in|for|at|near|around)\s+"
    r"(?P<location>.+?)"
    r"(?=\s+(?:today|tonight|tomorrow|this\s+(?:week|weekend)|"
    r"next\s+(?:week|monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b|[?!.]|$)",
    re.IGNORECASE,
)
_WEATHER_TIME = re.compile(
    r"\b(?:right now|current(?:ly)?|today|tonight|tomorrow|(?:this|the)\s+(?:week|weekend)|"
    r"next\s+(?:week|weekend|monday|tuesday|wednesday|thursday|friday|saturday|sunday)|"
    r"weekend|"
    r"monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b",
    re.IGNORECASE,
)
_REPAIR_PREFIX = re.compile(
    r"^\s*(?:no(?:pe)?|sorry|actually|correction|i\s+(?:said|meant)|"
    r"that(?:'s|\s+is)\s+wrong)\b[\s,:;-]*(?P<value>.*)$",
    re.IGNORECASE,
)
_NESTED_REPAIR_PREFIX = re.compile(
    r"^\s*(?:no(?:pe)?|i\s+(?:said|meant)|it(?:'s|\s+is))\b[\s,:;-]*",
    re.IGNORECASE,
)
_CONTRAST_REPAIR = re.compile(
    r"^\s*(?:(?:i\s+(?:said|meant)|actually)\s+)?"
    r"(?P<value>.+?)\s*[,;]\s*not\s+.+$",
    re.IGNORECASE,
)
_CONTEXTUAL_FOLLOWUP = re.compile(
    r"^\s*(?:and|then|so|what about|how about)\b[\s,:;-]*(?P<value>.*)$",
    re.IGNORECASE,
)
_AMBIGUOUS_REPAIR = re.compile(
    r"^\s*(?:no(?:pe)?|sorry|that(?:'s|\s+is)\s+(?:wrong|not it)|"
    r"i\s+(?:said|meant))\s*[?!.]*$",
    re.IGNORECASE,
)
_NEGATIVE_ONLY_REPAIR = re.compile(
    r"^\s*(?:no(?:pe)?[\s,:;-]*)?(?:i\s+(?:said|meant)\s+)?not\s+.+?[?!.]*$",
    re.IGNORECASE,
)
_CANCEL_TASK = re.compile(
    r"^\s*(?:never\s*mind|nevermind|cancel(?:\s+that)?|forget\s+it|stop|"
    r"no\s+thanks?|do\s+not\s+(?:check|search|look\s+up)(?:\s+the)?\s+weather|"
    r"i(?:'m|\s+am)\s+not\s+asking\s+about\s+(?:the\s+)?weather)\s*[?!.]*$",
    re.IGNORECASE,
)
_SENSITIVE_DETOUR = re.compile(
    r"\b(?:died|death|dead|grief|funeral|feel\s+sick|feeling\s+sick|"
    r"diagnos(?:is|ed)|suicid(?:e|al)|self[- ]harm|hurt|bleeding|"
    r"overwhelmed|scared|afraid|panic(?:king)?|smoke|fire)\b",
    re.IGNORECASE,
)
_RETRY_TASK = re.compile(
    r"^\s*(?:please\s+)?(?:try|search|check|look)\s+(?:that\s+)?again\s*[?!.]*$",
    re.IGNORECASE,
)
_EXPLANATION_FOLLOWUP = re.compile(
    r"^\s*(?:why|how\s+come|what\s+does\s+that\s+mean|tell\s+me\s+more|"
    r"explain(?:\s+that)?|is\s+that\s+(?:good|bad|normal))\s*[?!.]*$",
    re.IGNORECASE,
)
_VERIFY_ACTIVE_RESEARCH = re.compile(
    r"^\s*(?:please\s+)?(?:verify|check|open|inspect)\s+"
    r"(?:(?:that|the)\s+)?(?:source|result|link|claim)\s*[?!.]*$",
    re.IGNORECASE,
)
_EXPLICIT_TOPIC_SWITCH = re.compile(
    r"^\s*(?:and\s+)?(?:tell\s+me\s+about|switch\s+to|let\s+us\s+discuss|"
    r"actually\s+explain|now\s+tell\s+me|moving\s+on\s+to|can\s+we\s+discuss|"
    r"forget\s+that\s+and\s+explain|next\s+topic)\b",
    re.IGNORECASE,
)
_LOCATION_FORBIDDEN = re.compile(
    r"(?:https?://|www\.|@|"
    r"\b(?:home|work|office|my location|current location|here|there|"
    r"ignore|instructions?|prompt|system|assistant|tool|search query|"
    r"street|st\.|road|rd\.|avenue|ave\.|boulevard|blvd\.|lane|ln\.|"
    r"drive|dr\.|court|ct\.|apartment|apt\.|unit|postal|zip|coordinates?|"
    r"latitude|longitude)\b)",
    re.IGNORECASE,
)
_LOCATION_NONPLACE = {
    "it",
    "that",
    "this",
    "the city",
    "the place",
    "that is wrong",
    "that's wrong",
    "that is not it",
    "that's not it",
    "outside",
    "inside",
    "somewhere",
    "where i am",
    "thanks",
    "thank you",
    "that was right",
    "that is right",
    "that's right",
    "that works",
    "fine",
    "okay",
    "ok",
    "sure",
    "my dad died",
    "i feel sick",
    "the weekend",
    "weekend",
}
_EXPLICIT_WEATHER_DEFAULT = (
    re.compile(
        r"^\s*(?:please\s+)?(?:always\s+)?use\s+(?P<location>.+?)\s+as\s+my\s+"
        r"(?:default\s+)?weather\s+(?:place|location)\s*[?!.]*$",
        re.IGNORECASE,
    ),
    re.compile(
        r"^\s*(?:please\s+)?remember\s+that\s+my\s+default\s+weather\s+"
        r"(?:place|location)\s+is\s+(?P<location>.+?)\s*[?!.]*$",
        re.IGNORECASE,
    ),
)


def _clean_text(value: object, max_chars: int = 240) -> str:
    return " ".join(str(value or "").strip().split())[:max_chars]


def safe_coarse_location(value: object) -> str:
    """Return a bounded place label, excluding precise or inferred location data."""

    clean = _clean_text(value, MAX_LOCATION_CHARS).strip(" \t\r\n,;:.!?\"")
    clean = re.sub(r"^(?:the\s+)?(?:weather|forecast)\s+(?:in|for|at)\s+", "", clean, flags=re.IGNORECASE)
    if _LOCATION_FORBIDDEN.search(clean):
        return ""
    clean = _WEATHER_TIME.sub("", clean).strip(" \t\r\n,;:.!?\"")
    if (
        not clean
        or clean.casefold() in _LOCATION_NONPLACE
        or any(character.isdigit() for character in clean)
    ):
        return ""
    clean = re.sub(r"\s*,\s*", ", ", clean)
    if clean.count(",") > 2:
        return ""
    words = clean.replace(",", " ").split()
    if len(words) > MAX_LOCATION_WORDS:
        return ""
    for word in words:
        token = word.strip("'-")
        if not token or not all(character.isalpha() or character in "'-" for character in token):
            return ""
    return clean


def weather_location_from_text(text: object) -> str:
    query = _clean_text(text)
    if not _WEATHER_SIGNAL.search(query):
        return ""
    match = _WEATHER_LOCATION.search(query)
    return safe_coarse_location(match.group("location")) if match is not None else ""


def weather_time_from_text(text: object) -> str:
    query = _clean_text(text)
    match = _WEATHER_TIME.search(query)
    if match is None:
        return ""
    value = match.group(0).casefold()
    if value == "the weekend":
        return "this weekend"
    return "current" if value in {"current", "currently", "right now"} else value


def explicit_weather_default_location(text: object) -> str:
    clean = _clean_text(text, 160)
    for pattern in _EXPLICIT_WEATHER_DEFAULT:
        match = pattern.fullmatch(clean)
        if match is not None:
            return safe_coarse_location(match.group("location"))
    return ""


def correction_value(text: object) -> str:
    """Extract a high-confidence replacement value from an explicit repair turn."""

    clean = _clean_text(text, 120)
    contrast = _CONTRAST_REPAIR.fullmatch(clean)
    if (
        contrast is not None
        and contrast.group("value").strip().casefold() not in {"no", "nope"}
    ):
        return safe_coarse_location(contrast.group("value"))
    match = _REPAIR_PREFIX.fullmatch(clean)
    if match is not None:
        value = match.group("value").strip()
        for _ in range(2):
            next_value = _NESTED_REPAIR_PREFIX.sub("", value, count=1)
            if next_value == value:
                break
            value = next_value
        negative_replacement = re.fullmatch(
            r"not\s+[^,;]+[,;]\s*(?P<replacement>.+)",
            value,
            re.IGNORECASE,
        )
        if negative_replacement is not None:
            value = negative_replacement.group("replacement")
        elif re.match(r"^not\b", value, re.IGNORECASE):
            return ""
        return safe_coarse_location(value)
    return ""


def _weather_query(location: str, timeframe: str) -> str:
    when = timeframe or "current"
    return f"{when} weather in {location}"


def weather_result_matches(location: object, result: object) -> bool:
    """Require returned weather evidence to name the requested coarse place."""

    clean_location = safe_coarse_location(location)
    if not clean_location or not isinstance(result, Mapping):
        return False
    primary = clean_location.split(",", 1)[0]
    place_tokens = re.findall(r"[^\W\d_]+(?:['-][^\W\d_]+)*", primary)
    tokens = [
        token.casefold()
        for token in place_tokens
        if token.casefold() not in {"north", "south", "east", "west", "new", "the"}
    ]
    if not tokens:
        tokens = [token.casefold() for token in place_tokens]
    anchor = max(tokens, key=len, default="")
    rows = result.get("results", ())
    if not anchor or not isinstance(rows, list):
        return False
    evidence = " ".join(
        f"{row.get('title', '')} {row.get('excerpt', '')}"
        for row in rows
        if isinstance(row, Mapping)
    ).casefold()
    return bool(re.search(rf"\b{re.escape(anchor)}\b", evidence))


@dataclass(frozen=True)
class ToolTaskState:
    domain: str
    intent: str
    slots: tuple[tuple[str, str], ...]
    canonical_query: str
    revision: int
    status: str = "ready"

    def slot(self, name: str) -> str:
        return next((value for key, value in self.slots if key == name), "")


@dataclass(frozen=True)
class ConversationTurnPlan:
    request: dict[str, object] | None = None
    routing: str = ""
    turn_kind: str = "new"
    operation: str = "none"
    changed_slots: tuple[str, ...] = ()
    next_state: ToolTaskState | None = None
    preserve_task: bool = False
    resolved_request: str = ""
    clarification: str = ""

    def trusted_task_lines(self) -> tuple[str, ...]:
        state = self.next_state
        lines: list[str] = []
        if state is not None:
            lines.append(
                f"domain={state.domain}; intent={state.intent}; status={state.status}; "
                f"revision={state.revision}"
            )
        if self.resolved_request:
            lines.append(self.resolved_request.removeprefix("Resolved active request: ").rstrip("."))
        if self.clarification:
            lines.append(
                "Ask one short clarification for the missing or corrected "
                f"{self.clarification.replace('_', ' ')}; do not guess it."
            )
        return tuple(lines)

    def diagnostic_fields(self) -> dict[str, object]:
        state = self.next_state
        return {
            "conversation_turn_kind": self.turn_kind,
            "conversation_task_operation": self.operation,
            "conversation_task_domain": state.domain if state is not None else "",
            "conversation_task_revision": state.revision if state is not None else 0,
            "conversation_task_changed_slots": list(self.changed_slots),
            "conversation_task_clarification": self.clarification,
        }


class ConversationHarness:
    """Own session-scoped tool state and stage it with played conversation turns."""

    def __init__(self) -> None:
        self._active: ToolTaskState | None = None
        self._pending: ToolTaskState | None = None
        self._pending_plan: ConversationTurnPlan | None = None
        self._pending_research_succeeded = False
        self.repairs = 0
        self.contextual_rewrites = 0
        self.clarifications = 0
        self.topic_resets = 0

    @property
    def active(self) -> ToolTaskState | None:
        return self._active

    def clear(self) -> None:
        self._active = None
        self._pending = None
        self._pending_plan = None
        self._pending_research_succeeded = False

    def discard_pending(self) -> None:
        self._pending = None
        self._pending_plan = None
        self._pending_research_succeeded = False

    def stage(
        self,
        plan: ConversationTurnPlan,
        *,
        research_succeeded: bool | None = None,
    ) -> None:
        pending = plan.next_state
        if (
            pending is not None
            and plan.request is not None
            and research_succeeded is False
        ):
            pending = ToolTaskState(
                pending.domain,
                pending.intent,
                pending.slots,
                pending.canonical_query,
                pending.revision,
                "tool_failed",
            )
        self._pending = pending
        self._pending_plan = plan
        self._pending_research_succeeded = bool(research_succeeded)

    def commit(self) -> tuple[ConversationTurnPlan | None, bool]:
        plan = self._pending_plan
        if plan is None:
            return None, False
        research_succeeded = self._pending_research_succeeded
        self._active = self._pending
        if plan.operation == "repair":
            self.repairs += 1
        if plan.operation in {"repair", "inherit_location", "inherit_time", "use_default"}:
            self.contextual_rewrites += 1
        if plan.operation == "clarify":
            self.clarifications += 1
        if plan.operation == "reset":
            self.topic_resets += 1
        self.discard_pending()
        return plan, research_succeeded

    def snapshot(self) -> dict[str, object]:
        state = self._active
        return {
            "conversation_task_domain": state.domain if state is not None else "",
            "conversation_task_intent": state.intent if state is not None else "",
            "conversation_task_status": state.status if state is not None else "idle",
            "conversation_task_revision": state.revision if state is not None else 0,
            "conversation_task_repairs": self.repairs,
            "conversation_task_contextual_rewrites": self.contextual_rewrites,
            "conversation_task_clarifications": self.clarifications,
            "conversation_task_topic_resets": self.topic_resets,
        }

    @staticmethod
    def _request(query: str) -> dict[str, object]:
        return {"name": "web_search", "arguments": {"query": query, "max_results": 4}}

    def _weather_plan(
        self,
        text: str,
        *,
        base_routing: str,
        default_weather_location: str,
    ) -> ConversationTurnPlan:
        previous = self._active if self._active is not None and self._active.domain == "weather" else None
        explicit_location = weather_location_from_text(text)
        explicit_time = weather_time_from_text(text)
        previous_location = previous.slot("location") if previous is not None else ""
        previous_time = previous.slot("time") if previous is not None else ""
        location = explicit_location
        timeframe = explicit_time or previous_time or "current"
        operation = "new_task"
        turn_kind = "new"
        changed: tuple[str, ...] = ()

        repair = correction_value(text) if previous is not None else ""
        if previous is not None and _CANCEL_TASK.fullmatch(text):
            return ConversationTurnPlan(
                turn_kind="switch",
                operation="reset",
                next_state=None,
            )
        if previous is not None and _SENSITIVE_DETOUR.search(text):
            return ConversationTurnPlan(
                turn_kind="switch",
                operation="reset",
                next_state=None,
            )
        if previous is not None and _RETRY_TASK.fullmatch(text):
            return ConversationTurnPlan(
                request=self._request(previous.canonical_query),
                routing="contextual_retry",
                turn_kind="continue",
                operation="retry",
                next_state=ToolTaskState(
                    previous.domain,
                    previous.intent,
                    previous.slots,
                    previous.canonical_query,
                    previous.revision + 1,
                ),
                preserve_task=True,
                resolved_request=f"Resolved active request: {previous.canonical_query}.",
            )
        if previous is not None and _AMBIGUOUS_REPAIR.fullmatch(text):
            state = ToolTaskState(
                "weather",
                previous.intent,
                previous.slots,
                previous.canonical_query,
                previous.revision,
                "needs_clarification",
            )
            return ConversationTurnPlan(
                routing="conversation_clarification",
                turn_kind="clarify",
                operation="clarify",
                next_state=state,
                preserve_task=True,
                clarification="repair_value",
            )
        elif previous is not None and _NEGATIVE_ONLY_REPAIR.fullmatch(text):
            state = ToolTaskState(
                "weather",
                previous.intent,
                previous.slots,
                previous.canonical_query,
                previous.revision,
                "needs_clarification",
            )
            return ConversationTurnPlan(
                routing="conversation_clarification",
                turn_kind="clarify",
                operation="clarify",
                next_state=state,
                preserve_task=True,
                clarification="replacement location",
            )
        elif repair:
            location = repair
            operation = "repair"
            turn_kind = "correct"
            changed = ("location",)
        elif previous is not None and not _WEATHER_SIGNAL.search(text):
            followup = _CONTEXTUAL_FOLLOWUP.fullmatch(text)
            candidate_text = followup.group("value") if followup is not None else text
            candidate_time = weather_time_from_text(candidate_text)
            candidate_location = (
                safe_coarse_location(candidate_text)
                if previous.status == "needs_location" and not candidate_time
                else ""
            )
            if candidate_location:
                location = candidate_location
                operation = "fill_slot"
                turn_kind = "continue"
                changed = ("location",)
            elif candidate_time and previous_location:
                location = previous_location
                timeframe = candidate_time
                operation = "inherit_location"
                turn_kind = "continue"
                changed = ("time",)
            elif _EXPLANATION_FOLLOWUP.fullmatch(text):
                return ConversationTurnPlan(
                    turn_kind="continue",
                    operation="continue_context",
                    next_state=previous,
                    preserve_task=True,
                )
        elif previous is not None and not location and previous_location:
            location = previous_location
            operation = "inherit_location"
            turn_kind = "continue"
        if not location:
            remembered = safe_coarse_location(default_weather_location)
            if remembered:
                location = remembered
                operation = "use_default"
                turn_kind = "continue"
                changed = ("location",)
        revision = (previous.revision + 1) if previous is not None else 1
        if not location:
            state = ToolTaskState(
                "weather",
                "current_conditions",
                (("location", ""), ("time", timeframe)),
                "",
                revision,
                "needs_location",
            )
            return ConversationTurnPlan(
                routing="conversation_clarification",
                turn_kind="clarify",
                operation="clarify",
                next_state=state,
                preserve_task=True,
                clarification="location",
            )
        query = _weather_query(location, timeframe)
        state = ToolTaskState(
            "weather",
            "current_conditions",
            (("location", location), ("time", timeframe)),
            query,
            revision,
        )
        resolved = f"Resolved active request: {query}."
        return ConversationTurnPlan(
            request=self._request(query),
            routing=(
                "contextual_repair"
                if operation == "repair"
                else "contextual_followup"
                if previous is not None or operation == "use_default"
                else base_routing or "freshness_policy"
            ),
            turn_kind=turn_kind,
            operation=operation,
            changed_slots=changed,
            next_state=state,
            preserve_task=True,
            resolved_request=resolved,
        )

    def _research_plan(self, text: str) -> ConversationTurnPlan | None:
        previous = (
            self._active
            if self._active is not None and self._active.domain == "research"
            else None
        )
        if previous is None:
            return None
        if _RETRY_TASK.fullmatch(text) or _VERIFY_ACTIVE_RESEARCH.fullmatch(text):
            operation = (
                "verify_source"
                if _VERIFY_ACTIVE_RESEARCH.fullmatch(text)
                else "retry"
            )
            return ConversationTurnPlan(
                request=self._request(previous.canonical_query),
                routing=(
                    "contextual_verify"
                    if operation == "verify_source"
                    else "contextual_retry"
                ),
                turn_kind="continue",
                operation=operation,
                next_state=ToolTaskState(
                    previous.domain,
                    previous.intent,
                    previous.slots,
                    previous.canonical_query,
                    previous.revision + 1,
                ),
                preserve_task=True,
                resolved_request=(
                    f"Resolved active request: {previous.canonical_query}."
                ),
            )
        if _AMBIGUOUS_REPAIR.fullmatch(text) or _NEGATIVE_ONLY_REPAIR.fullmatch(text):
            return ConversationTurnPlan(
                routing="conversation_clarification",
                turn_kind="clarify",
                operation="clarify",
                next_state=previous,
                preserve_task=True,
                clarification="research correction",
            )
        repair = correction_value(text)
        if repair:
            query = f"{previous.canonical_query} excluding {repair}"
            state = ToolTaskState(
                "research",
                previous.intent,
                (("constraint", "exclusion"),),
                query,
                previous.revision + 1,
            )
            return ConversationTurnPlan(
                request=self._request(query),
                routing="contextual_repair",
                turn_kind="correct",
                operation="add_constraint",
                changed_slots=("constraint",),
                next_state=state,
                preserve_task=True,
                resolved_request=f"Resolved active request: {query}.",
            )
        if _EXPLANATION_FOLLOWUP.fullmatch(text):
            return ConversationTurnPlan(
                turn_kind="continue",
                operation="continue_context",
                next_state=previous,
                preserve_task=True,
            )
        return None

    def plan(
        self,
        text: object,
        base_request: Mapping[str, object] | None,
        base_routing: str,
        *,
        default_weather_location: str = "",
    ) -> ConversationTurnPlan:
        clean = _clean_text(text)
        active_weather = self._active is not None and self._active.domain == "weather"
        active_research = self._active is not None and self._active.domain == "research"
        if (
            _CANCEL_TASK.fullmatch(clean)
            or _SENSITIVE_DETOUR.search(clean)
            or (
                self._active is not None
                and _EXPLICIT_TOPIC_SWITCH.match(clean)
            )
        ):
            return ConversationTurnPlan(
                turn_kind="switch" if self._active is not None else "new",
                operation="reset" if self._active is not None else "none",
                next_state=None,
            )
        weather_turn = bool(
            _WEATHER_SIGNAL.search(clean)
            and not _NON_WEATHER_WEATHER_TEXT.search(clean)
            and (
                active_weather
                or _WEATHER_LOCATION.search(clean)
                or _WEATHER_TIME.search(clean)
                or re.search(
                    r"\b(?:what|how|is|are|will|could|should|weather|forecast)\b",
                    clean,
                    re.IGNORECASE,
                )
            )
        )
        repair_turn = active_weather and bool(
            correction_value(clean)
            or _AMBIGUOUS_REPAIR.fullmatch(clean)
            or _NEGATIVE_ONLY_REPAIR.fullmatch(clean)
        )
        contextual_turn = active_weather and bool(
            weather_time_from_text(clean)
            or (self._active is not None and self._active.status == "needs_location")
            or _RETRY_TASK.fullmatch(clean)
            or _EXPLANATION_FOLLOWUP.fullmatch(clean)
        )
        if weather_turn or repair_turn or contextual_turn:
            return self._weather_plan(
                clean,
                base_routing=base_routing,
                default_weather_location=default_weather_location,
            )
        if active_research:
            research_plan = self._research_plan(clean)
            if research_plan is not None:
                return research_plan
        if base_request is not None:
            query = _clean_text(
                (base_request.get("arguments") or {}).get("query", "")
                if isinstance(base_request.get("arguments"), Mapping)
                else clean
            )
            state = ToolTaskState(
                "research",
                "public_information",
                (),
                query,
                (self._active.revision + 1) if self._active is not None else 1,
            )
            return ConversationTurnPlan(
                request=dict(base_request),
                routing=base_routing,
                next_state=state,
                preserve_task=True,
            )
        if active_weather and _REPAIR_PREFIX.match(clean):
            return ConversationTurnPlan(
                turn_kind="clarify",
                operation="clarify",
                next_state=self._active,
                preserve_task=True,
                clarification="repair_value",
            )
        return ConversationTurnPlan(
            turn_kind="switch" if self._active is not None else "new",
            operation="reset" if self._active is not None else "none",
            next_state=None,
        )
