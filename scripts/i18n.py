"""CLI message catalog runtime.

Language resolution: $UBS_LANG > $LC_ALL > $LC_MESSAGES > $LANG > macOS
system language > en.
Supported: ko en ja zh. Anything else (including "C"/"POSIX") falls through to
the next step.

The macOS step exists because a process launched outside a login shell — an
IDE, a coding agent, launchd, cron — inherits LANG="C.UTF-8" or nothing at all,
and the old chain read that as "the user wants English" even on a Korean Mac.
The env vars still win when they name a supported language, so UBS_LANG=en is
the escape hatch (scripts/ubs.py and scripts/bootstrap-update.sh already use it
to keep machine-parsed subprocess output stable).
"""

from __future__ import annotations

import os
import subprocess
import sys

from i18n_messages import MESSAGES

_SUPPORTED = ("ko", "en", "ja", "zh")


def _normalize(raw: str) -> str:
    """Strip a locale string to its language subtag: ko_KR.UTF-8 -> ko."""
    return raw.split(".")[0].split("_")[0].lower()


def _system_lang() -> str | None:
    """The macOS system language, or None off macOS / when it isn't supported."""
    if sys.platform != "darwin":
        return None
    try:
        completed = subprocess.run(
            ["defaults", "read", "-g", "AppleLocale"],
            capture_output=True,
            text=True,
            timeout=2,
            check=True,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    code = _normalize(completed.stdout.strip())
    return code if code in _SUPPORTED else None


def _detect_lang() -> str:
    for name in ("UBS_LANG", "LC_ALL", "LC_MESSAGES", "LANG"):
        code = _normalize(os.environ.get(name, ""))
        if code in _SUPPORTED:
            return code
    return _system_lang() or "en"


LANG = _detect_lang()


def t(key: str, **kwargs) -> str:
    """Look up KEY in the resolved language, falling back to en, then the key itself."""
    table = MESSAGES.get(key)
    if table is None:
        return key
    template = table.get(LANG) or table.get("en") or key
    return template.format(**kwargs) if kwargs else template
