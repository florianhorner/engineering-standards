#!/usr/bin/env python3
"""Generate the Bash commit-msg hook from commit-rules.json.

Single source of truth: ../specs/commit-rules.json. The Bash hook is GENERATED
from this spec — three-loaders-drift is structurally impossible. Hand-editing
the emitted hook is an anti-pattern; rerun this script after rule changes.

Usage:
    python3 validator/generate-hook.py > /path/to/.git-hooks/commit-msg
    chmod +x /path/to/.git-hooks/commit-msg
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
RULES_PATH = REPO_ROOT / "specs" / "commit-rules.json"


def load_rules() -> dict[str, Any]:
    with RULES_PATH.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def shell_escape(value: str) -> str:
    """Escape a value for safe use inside single-quoted bash strings."""
    return value.replace("'", "'\"'\"'")


def emit_header(rules: dict[str, Any]) -> str:
    spec_url = rules["spec_url"]
    schema_version = rules["schema_version"]
    return f"""#!/usr/bin/env bash
# AUTO-GENERATED — DO NOT EDIT BY HAND.
#
# Source rules:    specs/commit-rules.json (schema_version {schema_version})
# Generator:       validator/generate-hook.py
# Spec URL:        {spec_url}
#
# Regenerate after any rules.json change:
#   python3 validator/generate-hook.py > ~/.git-hooks/commit-msg
#   chmod +x ~/.git-hooks/commit-msg
#
# Hand-edits will be overwritten on next regeneration. Modify the rules.json
# (or the generator) instead — three-loaders-drift is structurally impossible
# only if everyone respects this contract.

set -e
export LC_ALL=C.UTF-8
"""


def emit_constants(rules: dict[str, Any]) -> str:
    spec_url = shell_escape(rules["spec_url"])
    schema_version = shell_escape(rules["schema_version"])
    allowed_types = "|".join(rules["types"]["allowed"])
    max_length = int(rules["subject"]["max_length"])
    # Optional version prefix: gstack workspace-aware /ship puts a 4-component
    # ship-version (vMAJOR.MINOR.PATCH.MICRO) at the front of PR titles as a
    # landing-queue claim. When `subject.version_prefix.allowed` is true, the
    # format check accepts it as an optional leading group; direct commits
    # simply omit it. Short version prefixes stay blocked by VERSION_IN_SUBJECT.
    version_prefix = rules["subject"].get("version_prefix", {})
    if version_prefix.get("allowed"):
        prefix_group = "(" + version_prefix["pattern"] + ")?"
    else:
        prefix_group = ""
    return f"""
SPEC_URL='{spec_url}'
SCHEMA_VERSION='{schema_version}'
ALLOWED_TYPES_RE='^{prefix_group}({allowed_types})(\\([a-z0-9][a-z0-9-]*\\))?: .+'
SUBJECT_MAX={max_length}
"""


def emit_helpers() -> str:
    return r"""
emit_block() {
    local rule_id="$1"
    local message="$2"
    local fix_hint="$3"
    local offending="$4"
    {
        printf 'BLOCK: %s %s\n' "$rule_id" "$message"
        printf 'FIX: %s\n' "$fix_hint"
        printf 'SPEC: %s#%s\n' "$SPEC_URL" "$rule_id"
        printf 'OFFENDING: %s\n' "$offending"
    } >&2
    exit 1
}

emit_warn() {
    local rule_id="$1"
    local message="$2"
    local fix_hint="$3"
    local offending="$4"
    {
        printf 'WARN: %s %s\n' "$rule_id" "$message"
        printf 'FIX: %s\n' "$fix_hint"
        printf 'SPEC: %s#%s\n' "$SPEC_URL" "$rule_id"
        printf 'OFFENDING: %s\n' "$offending"
    } >&2
}
"""


def emit_message_loader() -> str:
    return r"""
MSG_FILE="${1:?commit-msg hook called without a message file argument}"
if [ ! -f "$MSG_FILE" ]; then
    printf 'ERROR: commit-msg hook: message file %s not found\n' "$MSG_FILE" >&2
    exit 2
fi

# Strip:
#   1. Everything below git's scissors line (`# ------------------------ >8 ...`)
#   2. Comment lines starting with `#`
# Preserve blank lines so subject vs body separation works.
CLEANED="$(awk '
    /^# ------------------------ >8 ------------------------/ { exit }
    /^#/ { next }
    { print }
' "$MSG_FILE")"

# Strip leading blank lines, then take the first line as the subject.
SUBJECT="$(printf '%s\n' "$CLEANED" | awk 'NF { print; exit }')"

# Body = everything after the first blank line following the subject.
BODY="$(printf '%s\n' "$CLEANED" | awk '
    BEGIN { state = 0 }
    state == 0 && NF { state = 1; next }
    state == 1 && !NF { state = 2; next }
    state == 2 { print }
')"
"""


def emit_exemption_check(rules: dict[str, Any]) -> str:
    patterns = rules["exemptions"]["subject_patterns"]
    combined = "|".join(f"({p})" for p in patterns)
    combined_escaped = shell_escape(combined)
    return f"""
# Exemptions: subjects matching these skip ALL further format checks.
EXEMPT_RE='{combined_escaped}'
if printf '%s' "$SUBJECT" | grep -E -q "$EXEMPT_RE"; then
    exit 0
fi
"""


def emit_subject_only_checks(rules: dict[str, Any]) -> str:
    chunks: list[str] = []
    for rule in rules["banned_patterns"]["subject_only"]:
        rule_id = shell_escape(rule["rule_id"])
        pattern = shell_escape(rule["pattern"])
        message = shell_escape(rule["message"])
        fix_hint = shell_escape(rule["fix_hint"])
        flags = rule.get("flags", "")
        grep_flags = "-E -q"
        if "i" in flags:
            grep_flags = "-E -i -q"
        chunks.append(
            f"""
# Subject-only banned pattern: {rule['rule_id']}
if printf '%s' "$SUBJECT" | grep {grep_flags} '{pattern}'; then
    emit_block '{rule_id}' '{message}' '{fix_hint}' "$SUBJECT"
fi
"""
        )
    return "".join(chunks)


def emit_format_check() -> str:
    return r"""
# Format check: type(scope): subject — type required, scope optional.
if ! printf '%s' "$SUBJECT" | grep -E -q "$ALLOWED_TYPES_RE"; then
    emit_block 'SUBJECT_FORMAT' \
        'Subject must match `type(scope): subject` with an allowed type.' \
        'Use one of: feat fix docs style refactor test chore ci build perf revert. Example: `fix(auth): handle expired token`.' \
        "$SUBJECT"
fi
"""


def emit_subject_length_check() -> str:
    return r"""
# Subject length check.
SUBJECT_LEN="$(printf '%s' "$SUBJECT" | awk '{ print length }')"
if [ "${SUBJECT_LEN:-0}" -gt "$SUBJECT_MAX" ]; then
    emit_block 'SUBJECT_TOO_LONG' \
        "Subject length ${SUBJECT_LEN} exceeds maximum ${SUBJECT_MAX} characters." \
        'Tighten the subject; move detail into the body.' \
        "$SUBJECT"
fi
"""


def emit_subject_trailing_period_check() -> str:
    return r"""
# Subject trailing-period check.
case "$SUBJECT" in
    *.)
        emit_block 'SUBJECT_TRAILING_PERIOD' \
            'Subject must not end with a period; subjects are not sentences.' \
            'Drop the trailing `.` from the subject line.' \
            "$SUBJECT"
        ;;
esac
"""


def emit_body_only_checks(rules: dict[str, Any]) -> str:
    chunks: list[str] = [
        """
# Body-only banned patterns. Skip entirely when body is empty.
if [ -n "$BODY" ]; then
"""
    ]
    for rule in rules["banned_patterns"]["body_only"]:
        rule_id = shell_escape(rule["rule_id"])
        pattern = shell_escape(rule["pattern"])
        message = shell_escape(rule["message"])
        fix_hint = shell_escape(rule["fix_hint"])
        flags = rule.get("flags", "")
        grep_flags = "-E -q"
        capture_grep_flags = "-E -m 1"
        if "i" in flags:
            grep_flags = "-E -i -q"
            capture_grep_flags = "-E -i -m 1"
        chunks.append(
            f"""
    # Body-only banned pattern: {rule['rule_id']}
    if printf '%s' "$BODY" | grep {grep_flags} '{pattern}'; then
        OFFENDING_LINE="$(printf '%s' "$BODY" | grep {capture_grep_flags} '{pattern}')"
        emit_block '{rule_id}' '{message}' '{fix_hint}' "$OFFENDING_LINE"
    fi
"""
        )
    chunks.append("fi\n")
    return "".join(chunks)


def emit_body_warn_rules(rules: dict[str, Any]) -> str:
    """Emit warn-only body rules (e.g. WHY_REQUIRED with local_severity=warn).

    Locally we cannot reliably compute lines_changed (the hook runs after
    `git add` but during commit). Conservative heuristic: if subject is
    `feat(...)` and body lacks a `Why:` line, emit a single WARN. CI does
    the authoritative block with real shortstat data.
    """
    chunks: list[str] = []
    for rule in rules["body"]["rules"]:
        if rule.get("rule_id") != "WHY_REQUIRED":
            continue
        if rule.get("local_severity") != "warn":
            continue
        rule_id = shell_escape(rule["rule_id"])
        message = shell_escape(rule["message"])
        fix_hint = shell_escape(rule["fix_hint"])
        chunks.append(
            f"""
# Local warn-only rule: {rule['rule_id']} (CI does the authoritative block).
# Heuristic: if subject is `feat(...)` and body lacks a `Why:` line, warn.
if printf '%s' "$SUBJECT" | grep -E -q '^feat(\\([a-z0-9][a-z0-9-]*\\))?: '; then
    if [ -z "$BODY" ] || ! printf '%s' "$BODY" | grep -E -q '^[Ww]hy:'; then
        emit_warn '{rule_id}' '{message}' '{fix_hint}' "$SUBJECT"
    fi
fi
"""
        )
    return "".join(chunks)


def emit_footer() -> str:
    return """
# All checks passed.
exit 0
"""


def main() -> None:
    rules = load_rules()
    parts = [
        emit_header(rules),
        emit_constants(rules),
        emit_helpers(),
        emit_message_loader(),
        emit_exemption_check(rules),
        emit_subject_only_checks(rules),
        emit_format_check(),
        emit_subject_length_check(),
        emit_subject_trailing_period_check(),
        emit_body_only_checks(rules),
        emit_body_warn_rules(rules),
        emit_footer(),
    ]
    sys.stdout.write("".join(parts))


if __name__ == "__main__":
    main()
