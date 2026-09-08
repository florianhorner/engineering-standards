#!/usr/bin/env python3
"""Shadow CodeRabbit leftover dispatcher — report-only decision engine.

Quota is per GitHub identity, not per repo. This job lives in
florianhorner/engineering-standards and enumerates Florian's repos the same
way fleet-audit-remote.sh does (`gh repo list florianhorner` on a hosted
runner). It never comments, never labels, and never writes to other repos.

First reviews stay on CodeRabbit auto_review. This dispatcher only *names*
at most one later review when the parsed 7-day included count is known and
under the ceiling. It does not burn leftover hourly slots.

Three runtime properties worth not regressing:

* The 7-day count is carried forward for up to SEVEN_DAY_MAX_AGE_HOURS when the
  newest CodeRabbit footer omits the integer. Without that, one count-less
  footer anywhere in the fleet holds every later tick forever.
* Per-repo and per-PR reads are isolated. One 403 must not cost the whole tick.
* Ineligible PRs are dropped from the PR-list row before their comments and
  reviews are fetched — that pair of requests is the fan-out risk.

`gh api --paginate` already merges JSON arrays across pages into one array, so
--slurp and page flattening are not needed here; per_page is raised instead to
cut the request count.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping, Optional, Sequence

OWNER = "florianhorner"
HUMAN_AUTHOR = "florianhorner"
ALLOWLISTED_FORKS = frozenset({"lightener-studio", "govee2mqtt-extended"})
TIEBREAK_REPO = "mammamiradio"
SEVEN_DAY_CEILING = 35
RECOVER_BAND_MAX = 29  # <30 in 7 days is the recover band
# How far back a 7-day count may be carried forward when the *newest* CodeRabbit
# footer omits the integer (the mammamiradio #1114 footer shape does). Without
# this, one count-less footer anywhere in the fleet pins the job to BUDGET_HELD
# forever and the ranking never gets exercised. Bounded so a carried-forward
# count can only be ~one day behind reality.
SEVEN_DAY_MAX_AGE_HOURS = 24
# Job summaries are capped at 1 MiB by GitHub. Every open PR on every owned repo
# gets a row, so cap the table rather than lose the whole summary.
MAX_TABLE_ROWS = 200
# GitHub defaults to 30 items per page; 100 is the maximum and cuts the request
# count by ~4x on long-lived PRs.
API_PER_PAGE = 100
# `gh repo list` page size. Hitting it exactly is reported as partial data
# rather than silently ranking a truncated fleet.
REPO_LIST_LIMIT = 200
ENABLE_RELPATH = Path(".github") / "coderabbit-dispatch.enabled"
DISPATCH_VAR = "CODERABBIT_DISPATCH"
CODERABBIT_LOGINS = frozenset({"coderabbitai[bot]", "coderabbitai"})
DEPENDABOT_LOGINS = frozenset({"dependabot[bot]", "dependabot", "app/dependabot"})

OUTCOME_DISABLED = "DISABLED"
OUTCOME_BUDGET_HELD = "BUDGET_HELD"
OUTCOME_WOULD_REVIEW = "WOULD_REVIEW"
OUTCOME_NONE = "NONE"

KIND_NEVER = "never-reviewed"
KIND_STALE = "head-stale"

CMD_INCREMENTAL = "@coderabbitai review"
CMD_FULL = "@coderabbitai full review"

# Footers observed on Team (mammamiradio #1114) and public rate-limit comments.
_RE_SEVEN_DAY = re.compile(
    r"(\d+)\s+included\s+PR\s+review\s+attempts\s+over\s+the\s+past\s+7\s+days",
    re.IGNORECASE,
)
_RE_REMAINING = re.compile(
    r"(\d+)\s+reviews?\s+(?:(?:are|is)\s+)?currently\s+available",
    re.IGNORECASE,
)
_RE_ALLOWANCE = re.compile(
    r"(?:current\s+)?allowance\s+at\s+(\d+)\s+reviews?\s+per\s+hour",
    re.IGNORECASE,
)
_RE_USED_CURRENT = re.compile(
    r"you(?:'|’|&apos;)ve\s+used\s+the\s+included\s+review\s+currently\s+available",
    re.IGNORECASE,
)
_RE_COVERED_COMMIT = re.compile(
    r'"coveredCommitId"\s*:\s*"([0-9a-f]{7,40})"',
    re.IGNORECASE,
)
_RE_BETWEEN_COMMITS = re.compile(
    r"between\s+[0-9a-f]{7,40}\s+and\s+([0-9a-f]{7,40})",
    re.IGNORECASE,
)

_PAUSE_MARKERS = (
    "review paused by coderabbit.ai",
    "## reviews paused",
    "coderabbit has automatically paused this review",
    "reviews paused",
)
_RATE_LIMIT_MARKERS = (
    "review limit reached",
    "review rate limited",
    "you've reached a temporary pr review limit",
    "you’ve reached a temporary pr review limit",
    "next review available in",
    "next included review available",
)


@dataclass
class Budget:
    seven_day: Optional[int] = None
    hourly_remaining: Optional[int] = None
    hourly_allowance: Optional[int] = None
    observed_at: Optional[str] = None
    snippet: str = ""
    # Set when seven_day was carried forward from an older footer because the
    # newest one omitted the integer. None means "read straight off the newest
    # budget-bearing comment".
    seven_day_observed_at: Optional[str] = None
    seven_day_age_hours: Optional[float] = None

    @property
    def known(self) -> bool:
        return self.seven_day is not None

    @property
    def seven_day_is_carried(self) -> bool:
        return self.seven_day is not None and self.seven_day_age_hours is not None


@dataclass
class ConsideredPR:
    repo: str
    number: int
    draft: bool
    author: str
    author_is_app: bool
    is_fork: bool
    repo_name: str
    head_sha: str
    created_at: str
    updated_at: str
    paused: bool = False
    last_review_sha: Optional[str] = None
    last_review_at: Optional[str] = None
    prior_review_count: int = 0
    change_stack_stale: bool = False
    skip_reason: Optional[str] = None
    candidate_kind: Optional[str] = None
    verdict: str = "skip"
    why: str = ""
    would_command: Optional[str] = None


@dataclass
class Report:
    outcome: str
    budget: Budget
    prs: list[ConsideredPR] = field(default_factory=list)
    selected: Optional[ConsideredPR] = None
    disable_reason: str = ""
    hold_reason: str = ""
    # Per-repo / per-PR read failures. Present means the fleet view is partial;
    # the tick still ranks what it could read instead of aborting outright.
    errors: list[str] = field(default_factory=list)

    def markdown(self) -> str:
        return render_markdown(self)


def repo_root_from_env() -> Path:
    raw = os.environ.get("CODERABBIT_DISPATCH_ROOT", "")
    if raw:
        return Path(raw)
    return Path(__file__).resolve().parent


def parse_budget(text: str) -> Budget:
    """Parse CodeRabbit footer / rate-limit prose. Missing 7-day count stays None."""
    if not text:
        return Budget()
    budget = Budget()
    m = _RE_SEVEN_DAY.search(text)
    if m:
        budget.seven_day = int(m.group(1))
    m = _RE_REMAINING.search(text)
    if m:
        budget.hourly_remaining = int(m.group(1))
    m = _RE_ALLOWANCE.search(text)
    if m:
        budget.hourly_allowance = int(m.group(1))
    if _RE_USED_CURRENT.search(text):
        budget.hourly_remaining = 0
    return budget


def _parse_ts(value: Optional[str]) -> Optional[datetime]:
    """Parse an ISO-8601 GitHub timestamp. Unparseable → None (never raises)."""
    if not value:
        return None
    text = value.strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def _hours_between(older: Optional[str], newer: Optional[str]) -> Optional[float]:
    a, b = _parse_ts(older), _parse_ts(newer)
    if a is None or b is None:
        return None
    return (b - a).total_seconds() / 3600.0


def _newer(a: Optional[str], b: Optional[str]) -> bool:
    """True if timestamp b is newer than a (missing a → True; missing b → False)."""
    if not b:
        return False
    if not a:
        return True
    return b > a


def _budget_has_signal(budget: Budget) -> bool:
    return (
        budget.seven_day is not None
        or budget.hourly_remaining is not None
        or budget.hourly_allowance is not None
        or bool(budget.snippet)
    )


def merge_budget(current: Budget, incoming: Budget, observed_at: Optional[str]) -> Budget:
    """Newest budget-bearing comment is the source of truth.

    The 7-day integer is *not* taken from the newest comment unconditionally:
    CodeRabbit posts two footer shapes, and the mammamiradio #1114 shape omits
    the integer entirely ("Your included PR review attempts over the past
    7 days set your current allowance at 5 reviews per hour"). Taking the newest
    comment wholesale meant a single count-less footer anywhere in the fleet
    pinned the job to BUDGET_HELD forever, so the ranking never ran.

    Carry-forward is handled in collect_budget(); this function only tracks the
    newest budget-bearing observation.
    """
    if not _budget_has_signal(incoming):
        return current
    if not _newer(current.observed_at, observed_at):
        return current
    incoming.observed_at = observed_at
    return incoming


def is_coderabbit_login(login: str) -> bool:
    lowered = (login or "").lower()
    return lowered in {x.lower() for x in CODERABBIT_LOGINS} or lowered.startswith("coderabbit")


def is_dependabot_login(login: str) -> bool:
    lowered = (login or "").lower()
    return lowered in {x.lower() for x in DEPENDABOT_LOGINS} or "dependabot" in lowered


def is_github_app_author(login: str, is_bot: bool, user_type: str = "") -> bool:
    if is_bot:
        return True
    if (user_type or "").lower() == "bot":
        return True
    login = login or ""
    if login.endswith("[bot]"):
        return True
    if login.lower().startswith("app/"):
        return True
    return False


def body_is_rate_limit(text: str) -> bool:
    lowered = (text or "").lower()
    return any(m in lowered for m in _RATE_LIMIT_MARKERS)


def body_is_paused(text: str) -> bool:
    lowered = (text or "").lower()
    return any(m in lowered for m in _PAUSE_MARKERS)


def sha_matches(head: str, candidate: str) -> bool:
    if not head or not candidate:
        return False
    a, b = head.lower(), candidate.lower()
    n = min(len(a), len(b))
    if n < 7:
        return a == b
    return a[:n] == b[:n] or a.startswith(b) or b.startswith(a)


def _author_from_pr(pr: Mapping[str, Any]) -> tuple[str, bool, str]:
    author = pr.get("author") or pr.get("user") or {}
    if not isinstance(author, dict):
        return "", True, ""
    login = str(author.get("login") or "")
    is_bot = bool(author.get("is_bot") or author.get("isBot") or False)
    user_type = str(author.get("type") or "")
    return login, is_bot, user_type


def prefilter_skip_reason(
    *,
    repo_name: str,
    is_fork: bool,
    pr: Mapping[str, Any],
) -> Optional[str]:
    """Skip reasons decidable from the PR list row alone — no extra API calls.

    Split out of classify_pr so fetch_snapshot can drop a PR *before* paying two
    requests for its comments and reviews. Ordering is load-bearing: it is the
    order the reasons are reported in, and the tests pin it.
    """
    login, is_bot, user_type = _author_from_pr(pr)
    draft = bool(pr.get("isDraft") if "isDraft" in pr else pr.get("draft"))
    if is_fork and repo_name not in ALLOWLISTED_FORKS:
        return "non-allowlisted fork — never comment on upstream, never dispatch"
    if draft:
        return "draft"
    if is_dependabot_login(login):
        return "Dependabot"
    if is_github_app_author(login, is_bot, user_type):
        return "GitHub App author"
    if login != HUMAN_AUTHOR:
        return f"author `{login or '(none)'}` is not human `{HUMAN_AUTHOR}`"
    return None


def classify_pr(
    *,
    repo: str,
    repo_name: str,
    is_fork: bool,
    pr: Mapping[str, Any],
    comments: Sequence[Mapping[str, Any]],
    reviews: Sequence[Mapping[str, Any]],
) -> ConsideredPR:
    number = int(pr.get("number") or 0)
    draft = bool(pr.get("isDraft") if "isDraft" in pr else pr.get("draft"))
    login, is_bot, user_type = _author_from_pr(pr)
    head = str(pr.get("headRefOid") or "")
    if not head:
        head_obj = pr.get("head") or {}
        if isinstance(head_obj, dict):
            head = str(head_obj.get("sha") or "")
    created = str(pr.get("createdAt") or pr.get("created_at") or "")
    updated = str(pr.get("updatedAt") or pr.get("updated_at") or "")
    app_author = is_github_app_author(login, is_bot, user_type)

    row = ConsideredPR(
        repo=repo,
        number=number,
        draft=draft,
        author=login or "(none)",
        author_is_app=app_author,
        is_fork=is_fork,
        repo_name=repo_name,
        head_sha=head,
        created_at=created,
        updated_at=updated,
    )

    prefilter = prefilter_skip_reason(repo_name=repo_name, is_fork=is_fork, pr=pr)
    if prefilter:
        return _skip(row, prefilter)

    paused = False
    last_sha: Optional[str] = None
    last_at: Optional[str] = None
    prior = 0
    saw_change_stack = False
    covered_from_stack: Optional[str] = None

    events: list[tuple[str, str, str]] = []
    for comment in comments:
        user = comment.get("user") or comment.get("author") or {}
        clogin = str(user.get("login") or "")
        body = str(comment.get("body") or "")
        when = str(comment.get("created_at") or comment.get("createdAt") or "")
        events.append((clogin, body, when))
    for review in reviews:
        user = review.get("user") or {}
        clogin = str(user.get("login") or "")
        body = str(review.get("body") or "")
        when = str(review.get("submitted_at") or review.get("submittedAt") or "")
        commit_id = str(review.get("commit_id") or review.get("commitId") or "")
        events.append((clogin, body, when))
        if is_coderabbit_login(clogin) and commit_id and not body_is_rate_limit(body):
            prior += 1
            if _newer(last_at, when) or last_sha is None:
                last_sha = commit_id
                last_at = when

    # Comments can carry pause / coverage / budget even when reviews do not.
    comment_review_count = 0
    for clogin, body, when in events:
        if not is_coderabbit_login(clogin):
            continue
        if body_is_paused(body):
            paused = True
        if "review_stack_entry" in body or "change-stack" in body.lower():
            saw_change_stack = True
        if body_is_rate_limit(body):
            continue
        covered = _RE_COVERED_COMMIT.findall(body or "")
        between = _RE_BETWEEN_COMMITS.findall(body or "")
        sha = (covered[-1] if covered else None) or (between[-1] if between else None)
        if not sha:
            continue
        if covered:
            covered_from_stack = covered[-1]
        if _newer(last_at, when) or last_sha is None:
            last_sha = sha
            last_at = when
        comment_review_count += 1

    if prior == 0 and comment_review_count:
        prior = comment_review_count

    row.paused = paused
    row.last_review_sha = last_sha
    row.last_review_at = last_at
    row.prior_review_count = prior
    if saw_change_stack and covered_from_stack and not sha_matches(head, covered_from_stack):
        row.change_stack_stale = True

    head_reviewed = bool(last_sha and sha_matches(head, last_sha))

    if paused and head_reviewed:
        return _skip(
            row,
            "paused and HEAD already reviewed (mammamiradio #1114 class) — wait until HEAD is unreviewed",
        )

    if head_reviewed:
        return _skip(row, "HEAD already reviewed — not an incremental candidate")

    if last_sha is None:
        row.candidate_kind = KIND_NEVER
        row.would_command = CMD_FULL
        row.why = "never-reviewed HEAD — first-review backup if CodeRabbit auto_review missed it"
    else:
        row.candidate_kind = KIND_STALE
        row.would_command = CMD_FULL if row.change_stack_stale else CMD_INCREMENTAL
        extra = "; change-stack stale → full review" if row.change_stack_stale else ""
        row.why = (
            f"HEAD-stale (last CodeRabbit commit `{_short_sha(last_sha)}` vs HEAD `{_short_sha(head)}`)"
            f"{extra}"
        )
    return row


def _short_sha(sha: str) -> str:
    return sha[:7] if sha else "?"


def _skip(row: ConsideredPR, reason: str) -> ConsideredPR:
    row.skip_reason = reason
    row.verdict = "skip"
    row.why = reason
    row.candidate_kind = None
    row.would_command = None
    return row


def rank_key(row: ConsideredPR) -> tuple[Any, ...]:
    """never-reviewed first, then oldest HEAD-stale, mammamiradio only as tie-break."""
    kind_rank = 0 if row.candidate_kind == KIND_NEVER else 1
    if row.candidate_kind == KIND_NEVER:
        age = row.created_at or row.updated_at or ""
    else:
        age = row.last_review_at or row.created_at or ""
    tie = 0 if row.repo_name == TIEBREAK_REPO else 1
    return (kind_rank, age, tie, row.repo, row.number)


def collect_budget(
    comments_by_pr: Mapping[tuple[str, int], Sequence[Mapping[str, Any]]],
    reviews_by_pr: Mapping[tuple[str, int], Sequence[Mapping[str, Any]]],
) -> Budget:
    budget = Budget()
    blobs: list[tuple[str, str]] = []
    for mapping, time_keys in (
        (comments_by_pr, ("created_at", "createdAt")),
        (reviews_by_pr, ("submitted_at", "submittedAt")),
    ):
        for events in mapping.values():
            for event in events:
                user = event.get("user") or event.get("author") or {}
                login = str(user.get("login") or "")
                if not is_coderabbit_login(login):
                    continue
                body = str(event.get("body") or "")
                when = ""
                for key in time_keys:
                    if event.get(key):
                        when = str(event.get(key))
                        break
                blobs.append((when, body))
    blobs.sort(key=lambda x: x[0])
    last_seven: Optional[int] = None
    last_seven_at: Optional[str] = None
    for when, body in blobs:
        parsed = parse_budget(body)
        parsed.snippet = _budget_snippet(body)
        if parsed.seven_day is not None:
            last_seven = parsed.seven_day
            last_seven_at = when or None
        budget = merge_budget(budget, parsed, when or None)
    if budget.seven_day is not None:
        budget.seven_day_observed_at = budget.observed_at
        return budget
    return _carry_forward_seven_day(budget, last_seven, last_seven_at)


def _carry_forward_seven_day(
    budget: Budget,
    last_seven: Optional[int],
    last_seven_at: Optional[str],
) -> Budget:
    """Reuse the most recent footer that actually carried the 7-day integer.

    Bounded by SEVEN_DAY_MAX_AGE_HOURS relative to the newest budget-bearing
    comment, so a carried count is at most ~a day behind. Outside the window,
    or with unparseable timestamps, the count stays unknown and the job holds.
    """
    if last_seven is None:
        return budget
    age = _hours_between(last_seven_at, budget.observed_at)
    if age is None or age < 0 or age > SEVEN_DAY_MAX_AGE_HOURS:
        return budget
    budget.seven_day = last_seven
    budget.seven_day_observed_at = last_seven_at
    budget.seven_day_age_hours = age
    return budget


def _budget_snippet(body: str) -> str:
    for line in body.splitlines():
        lowered = line.lower()
        if "currently available" in lowered or "past 7 days" in lowered or "allowance at" in lowered:
            return line.strip()[:240]
    return ""


def budget_hold_reason(budget: Budget) -> Optional[str]:
    """Fail closed if the 7-day count cannot be read. Do not burn leftover hours."""
    if not budget.known:
        extra = ""
        if budget.hourly_allowance is not None:
            extra = (
                f" Hourly allowance parses as {budget.hourly_allowance}/hour"
                f" (Team Fair Usage band is not an exact 7-day count)."
            )
        return (
            "7-day included count unknown — fail closed, no WOULD_REVIEW. "
            f"No CodeRabbit footer in the last {SEVEN_DAY_MAX_AGE_HOURS}h carried the integer."
            + extra
        )
    if budget.seven_day >= SEVEN_DAY_CEILING:
        return (
            f"7-day included count {budget.seven_day} is at/above ceiling {SEVEN_DAY_CEILING} "
            f"(don't get worse; recover band is <{RECOVER_BAND_MAX + 1})"
        )
    if budget.hourly_remaining == 0:
        return "hourly remaining is 0 — a request this hour would rate-limit, not review"
    return None


def evaluate(
    *,
    repos: Sequence[Mapping[str, Any]],
    pulls_by_repo: Mapping[str, Sequence[Mapping[str, Any]]],
    comments_by_pr: Mapping[tuple[str, int], Sequence[Mapping[str, Any]]],
    reviews_by_pr: Mapping[tuple[str, int], Sequence[Mapping[str, Any]]],
    enabled_file_present: bool,
    dispatch_var: str = "1",
    errors: Sequence[str] = (),
) -> Report:
    if not enabled_file_present:
        return Report(
            outcome=OUTCOME_DISABLED,
            budget=Budget(),
            disable_reason=f"`{ENABLE_RELPATH}` is absent",
        )
    if dispatch_var == "0":
        return Report(
            outcome=OUTCOME_DISABLED,
            budget=Budget(),
            disable_reason=f"`{DISPATCH_VAR}=0`",
        )

    budget = collect_budget(comments_by_pr, reviews_by_pr)
    rows: list[ConsideredPR] = []
    for repo in repos:
        nwo = str(repo.get("nameWithOwner") or "")
        name = str(repo.get("name") or (nwo.split("/")[-1] if nwo else ""))
        if repo.get("isArchived") is True or str(repo.get("isArchived")).lower() == "true":
            continue
        is_fork = repo.get("isFork") is True or str(repo.get("isFork")).lower() == "true"
        for pr in pulls_by_repo.get(nwo, []):
            number = int(pr.get("number") or 0)
            rows.append(
                classify_pr(
                    repo=nwo,
                    repo_name=name,
                    is_fork=is_fork,
                    pr=pr,
                    comments=comments_by_pr.get((nwo, number), ()),
                    reviews=reviews_by_pr.get((nwo, number), ()),
                )
            )

    candidates = [r for r in rows if r.candidate_kind]
    candidates.sort(key=rank_key)
    hold = budget_hold_reason(budget)
    selected: Optional[ConsideredPR] = None
    if hold:
        outcome = OUTCOME_BUDGET_HELD
        for row in candidates:
            row.verdict = "held"
            row.why = f"{row.why} — not selected: {hold}"
    elif not candidates:
        outcome = OUTCOME_NONE
    else:
        selected = candidates[0]
        selected.verdict = OUTCOME_WOULD_REVIEW
        selected.why = (
            f"{selected.why} — the one review this hour "
            f"(rank: {selected.candidate_kind}"
            f"{', mammamiradio tie-break' if selected.repo_name == TIEBREAK_REPO and _is_tiebreak_win(selected, candidates) else ''})"
        )
        for row in candidates[1:]:
            row.verdict = "skip"
            row.why = f"{row.why} — not selected: at most one WOULD_REVIEW per tick"
        outcome = OUTCOME_WOULD_REVIEW

    return Report(
        outcome=outcome,
        budget=budget,
        prs=rows,
        selected=selected,
        hold_reason=hold or "",
        errors=list(errors),
    )


def _is_tiebreak_win(selected: ConsideredPR, ranked: Sequence[ConsideredPR]) -> bool:
    if len(ranked) < 2 or selected.repo_name != TIEBREAK_REPO:
        return False
    other = ranked[1]
    return rank_key(selected)[:2] == rank_key(other)[:2]


def render_markdown(report: Report) -> str:
    b = report.budget
    seven = str(b.seven_day) if b.seven_day is not None else "unknown"
    remaining = str(b.hourly_remaining) if b.hourly_remaining is not None else "unparsed"
    allowance = f"{b.hourly_allowance}/hour" if b.hourly_allowance is not None else "unparsed"
    recover = ""
    if b.seven_day is not None:
        if b.seven_day <= RECOVER_BAND_MAX:
            recover = f" (recover band: <{RECOVER_BAND_MAX + 1})"
        elif b.seven_day >= SEVEN_DAY_CEILING:
            recover = f" (at/above ceiling {SEVEN_DAY_CEILING} — don't get worse)"
        else:
            recover = f" (between recover band and ceiling {SEVEN_DAY_CEILING})"

    if b.seven_day_is_carried:
        age = f"{b.seven_day_age_hours:.1f}h"
        seven = (
            f"{b.seven_day} (carried forward from a footer {age} older than the newest one, "
            f"which omitted the integer; window {SEVEN_DAY_MAX_AGE_HOURS}h)"
        )

    lines = [
        "# CodeRabbit dispatch (shadow)",
        "",
        f"**Outcome:** `{report.outcome}`",
        "**Mode:** shadow — job summary only. No comments, no labels, no writes to other repos.",
        f"**7-day included count:** {seven}{recover}",
        f"**Hourly remaining:** {remaining}",
        f"**Hourly allowance:** {allowance}",
        f"**Ceiling:** {SEVEN_DAY_CEILING} included reviews in 7 days. Fail closed if unreadable.",
    ]
    if report.disable_reason:
        lines.append(f"**Kill switch:** {report.disable_reason}")
    if report.hold_reason:
        lines.append(f"**Budget:** {report.hold_reason}")
    if report.selected:
        lines.append(
            f"**Would review:** `{report.selected.repo}#{report.selected.number}` "
            f"with `{report.selected.would_command}`"
        )
    elif report.outcome == OUTCOME_WOULD_REVIEW:
        lines.append("**Would review:** (none)")
    lines.extend(
        [
            "",
            "First reviews stay on CodeRabbit `reviews.auto_review.enabled`. "
            "This dispatcher does not spend leftover hourly slots just because they exist.",
            "",
            "## Considered PRs",
            "",
            "| Repo | PR | Draft | Author | Verdict | Why |",
            "|---|---|---|---|---|---|",
        ]
    )
    # Candidates and held rows first: a 1 MiB summary cap must never drop the
    # rows the decision was actually made from.
    ordered = [r for r in report.prs if r.candidate_kind] + [
        r for r in report.prs if not r.candidate_kind
    ]
    for row in ordered[:MAX_TABLE_ROWS]:
        draft = "yes" if row.draft else "no"
        why = row.why.replace("|", "\\|")
        lines.append(
            f"| `{row.repo}` | {row.number} | {draft} | `{row.author}` | `{row.verdict}` | {why} |"
        )
    if len(ordered) > MAX_TABLE_ROWS:
        omitted = len(ordered) - MAX_TABLE_ROWS
        lines.append(
            f"| _({omitted} more)_ | | | | `skip` | "
            f"table capped at {MAX_TABLE_ROWS} rows; all omitted rows were skips |"
        )
    if not report.prs and report.outcome != OUTCOME_DISABLED:
        lines.append("| _(none)_ | | | | | no open PRs on in-scope repos |")
    if report.errors:
        lines.extend(
            [
                "",
                "## Partial data",
                "",
                f"{len(report.errors)} repo/PR read(s) failed. Those were skipped; the rest "
                "of the fleet was still ranked.",
                "",
            ]
        )
        lines.extend(f"- {err}" for err in report.errors[:MAX_TABLE_ROWS])
        if len(report.errors) > MAX_TABLE_ROWS:
            lines.append(f"- _({len(report.errors) - MAX_TABLE_ROWS} more omitted)_")
    lines.extend(
        [
            "",
            "_Report-only. Live `@coderabbitai review` / GitHub App writes are a follow-up PR, not this job._",
        ]
    )
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Live GitHub enumeration (hosted runner / gh CLI)
# ---------------------------------------------------------------------------


class GhError(RuntimeError):
    pass


def gh_json(args: Sequence[str]) -> Any:
    proc = subprocess.run(
        ["gh", *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip() or f"gh exited {proc.returncode}"
        raise GhError(err)
    text = proc.stdout.strip()
    if not text:
        return None
    return json.loads(text)


def fetch_snapshot() -> tuple[
    list[dict[str, Any]],
    dict[str, list[dict[str, Any]]],
    dict[tuple[str, int], list[dict[str, Any]]],
    dict[tuple[str, int], list[dict[str, Any]]],
    list[str],
]:
    """Enumerate owned repos and their open PRs.

    Two properties this function is responsible for:

    1. **Per-repo isolation.** One archived repo with issues disabled, one 403,
       or one timeout used to abort the whole tick and produce no summary at
       all. Every per-repo and per-PR call is isolated; failures are collected
       and rendered, and the rest of the fleet is still ranked. Only the
       top-level repo enumeration is fatal — without it there is nothing to do.
    2. **No N+1 on ineligible PRs.** Comments and reviews cost two requests per
       PR. Drafts, Dependabot, GitHub App authors and non-allowlisted forks are
       dropped from the PR-list row first, so those requests are never made.
       Consequence, deliberately: budget footers are only harvested from
       eligible PRs — which is where CodeRabbit posts them anyway, since the
       shipped yaml has `drafts: false` and ignores the bot authors.
    """
    errors: list[str] = []
    repos = gh_json(
        [
            "repo",
            "list",
            OWNER,
            "--limit",
            str(REPO_LIST_LIMIT),
            "--json",
            "nameWithOwner,name,isFork,isArchived",
        ]
    )
    if not isinstance(repos, list):
        raise GhError("gh repo list did not return a JSON array — fail closed")
    if len(repos) >= REPO_LIST_LIMIT:
        errors.append(
            f"`gh repo list` returned {len(repos)} repos, the requested limit — "
            f"the fleet may be truncated; raise REPO_LIST_LIMIT"
        )
    pulls_by_repo: dict[str, list[dict[str, Any]]] = {}
    comments_by_pr: dict[tuple[str, int], list[dict[str, Any]]] = {}
    reviews_by_pr: dict[tuple[str, int], list[dict[str, Any]]] = {}
    for repo in repos:
        nwo = str(repo.get("nameWithOwner") or "")
        if not nwo:
            continue
        if repo.get("isArchived") is True:
            continue
        name = str(repo.get("name") or nwo.split("/")[-1])
        is_fork = repo.get("isFork") is True
        try:
            pulls = gh_json(
                [
                    "pr",
                    "list",
                    "--repo",
                    nwo,
                    "--state",
                    "open",
                    "--limit",
                    "100",
                    "--json",
                    "number,title,isDraft,author,headRefOid,createdAt,updatedAt,url",
                ]
            )
        except (GhError, json.JSONDecodeError) as exc:
            errors.append(f"`{nwo}`: open PRs unreadable ({_one_line(exc)}) — repo skipped")
            continue
        if pulls is None:
            pulls = []
        if not isinstance(pulls, list):
            errors.append(f"`{nwo}`: `gh pr list` was not a JSON array — repo skipped")
            continue
        pulls_by_repo[nwo] = pulls
        for pr in pulls:
            number = int(pr.get("number") or 0)
            if prefilter_skip_reason(repo_name=name, is_fork=is_fork, pr=pr):
                # Skip reason is already decided; comments/reviews cannot change it.
                comments_by_pr[(nwo, number)] = []
                reviews_by_pr[(nwo, number)] = []
                continue
            comments, err = _fetch_list(f"repos/{nwo}/issues/{number}/comments")
            if err:
                errors.append(f"`{nwo}#{number}`: comments unreadable ({err}) — PR skipped")
                pulls_by_repo[nwo] = [p for p in pulls_by_repo[nwo] if p is not pr]
                continue
            reviews, err = _fetch_list(f"repos/{nwo}/pulls/{number}/reviews")
            if err:
                errors.append(f"`{nwo}#{number}`: reviews unreadable ({err}) — PR skipped")
                pulls_by_repo[nwo] = [p for p in pulls_by_repo[nwo] if p is not pr]
                continue
            comments_by_pr[(nwo, number)] = comments
            reviews_by_pr[(nwo, number)] = reviews
    return repos, pulls_by_repo, comments_by_pr, reviews_by_pr, errors


def _one_line(exc: BaseException) -> str:
    return " ".join(str(exc).split())[:200] or exc.__class__.__name__


def _fetch_list(endpoint: str) -> tuple[list[dict[str, Any]], str]:
    """GET a paginated array endpoint. Returns (rows, error); error wins.

    `gh api --paginate` merges JSON arrays across pages into one array, so no
    --slurp/flatten is needed; per_page is raised to cut the request count.
    """
    sep = "&" if "?" in endpoint else "?"
    try:
        data = gh_json(["api", "--paginate", f"{endpoint}{sep}per_page={API_PER_PAGE}"])
    except (GhError, json.JSONDecodeError) as exc:
        return [], _one_line(exc)
    if data is None:
        return [], ""
    if not isinstance(data, list):
        return [], "response was not a JSON array"
    return data, ""


def run_live(root: Path) -> Report:
    reason = None
    enabled = (root / ENABLE_RELPATH).is_file()
    dispatch_var = os.environ.get(DISPATCH_VAR, "1")
    if not enabled:
        reason = f"`{ENABLE_RELPATH}` is absent"
    elif dispatch_var == "0":
        reason = f"`{DISPATCH_VAR}=0`"
    if reason:
        return Report(outcome=OUTCOME_DISABLED, budget=Budget(), disable_reason=reason)
    repos, pulls, comments, reviews, errors = fetch_snapshot()
    return evaluate(
        repos=repos,
        pulls_by_repo=pulls,
        comments_by_pr=comments,
        reviews_by_pr=reviews,
        enabled_file_present=True,
        dispatch_var=dispatch_var,
        errors=errors,
    )


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Shadow CodeRabbit leftover dispatcher (report-only). No --apply."
    )
    parser.add_argument(
        "--root",
        default=None,
        help="Repo root containing .github/coderabbit-dispatch.enabled (default: this file's directory)",
    )
    args = parser.parse_args(argv)
    root = Path(args.root) if args.root else repo_root_from_env()
    try:
        report = run_live(root)
    except GhError as exc:
        sys.stderr.write(f"FAIL gh: {exc}\n")
        return 1
    except json.JSONDecodeError as exc:
        sys.stderr.write(f"FAIL unreadable gh JSON ({exc}) — fail closed\n")
        return 1
    text = report.markdown()
    sys.stdout.write(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(text)
            if not text.endswith("\n"):
                fh.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
