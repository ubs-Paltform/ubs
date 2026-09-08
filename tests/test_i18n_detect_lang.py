#!/usr/bin/env python3
"""scripts/i18n.py의 _detect_lang 자체에 대한 표 기반 단위 테스트(#60).

LC_ALL > LC_MESSAGES > LANG 폴백 체인, UBS_LANG 최우선, prefix 매칭,
미지원 값 처리, 그리고 env 가 쓸 값을 주지 못할 때의 macOS 시스템 언어
폴백을 검증한다. 시스템 조회(_system_lang)는 항상 mock 한다 — 실제 호스트의
언어 설정에 따라 결과가 달라지면 표가 의미를 잃는다. bash 쪽(ubs_detect_lang)의 동일한 표는
tests/test-i18n-detect-lang.sh에 있다 — 두 알고리즘이 지금 다르게 구현돼
있을 수 있는 문제(#54)는 별도이므로 여기서는 python 구현 자체가 기대 동작을
만족하는지만 본다.
"""

from __future__ import annotations

import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import i18n  # noqa: E402

UNSET = object()

_ENV_NAMES = ("UBS_LANG", "LC_ALL", "LC_MESSAGES", "LANG")

# (설명, UBS_LANG, LC_ALL, LC_MESSAGES, LANG, 시스템언어, 기대값)
# 시스템언어 None = macOS 가 아니거나 지원하지 않는 언어인 경우.
CASES = [
    ("UBS_LANG=ko", "ko", UNSET, UNSET, UNSET, None, "ko"),
    ("LANG만 ja_JP.UTF-8", UNSET, UNSET, UNSET, "ja_JP.UTF-8", None, "ja"),
    ("LANG=C + 시스템언어 없음이면 en", UNSET, UNSET, UNSET, "C", None, "en"),
    ("아무것도 없고 시스템언어도 없으면 en", UNSET, UNSET, UNSET, UNSET, None, "en"),
    ("지원하지 않는 로케일 + 시스템언어 없음이면 en", UNSET, UNSET, UNSET, "fr_FR.UTF-8", None, "en"),
    ("UBS_LANG이 LANG보다 우선", "en", UNSET, UNSET, "ko_KR.UTF-8", None, "en"),
    ("LC_ALL이 LANG보다 우선", UNSET, "zh_CN.UTF-8", UNSET, "ko_KR.UTF-8", None, "zh"),
    ("LC_MESSAGES가 LANG보다 우선", UNSET, UNSET, "ja_JP.UTF-8", "ko_KR.UTF-8", None, "ja"),
    ("LC_ALL이 LC_MESSAGES보다 우선", UNSET, "zh_TW.UTF-8", "ja_JP.UTF-8", "ko_KR.UTF-8", None, "zh"),
    ("미지원 LC_ALL은 건너뛰고 LC_MESSAGES 사용", UNSET, "fr_FR.UTF-8", "ja_JP.UTF-8", "ko_KR.UTF-8", None, "ja"),
    ("LANG=zh_CN.UTF-8", UNSET, UNSET, UNSET, "zh_CN.UTF-8", None, "zh"),
    ("LANG=en_US.UTF-8", UNSET, UNSET, UNSET, "en_US.UTF-8", None, "en"),
    ("UBS_LANG 빈 문자열은 미설정 취급", "", UNSET, UNSET, "ja_JP.UTF-8", None, "ja"),
    # 아래부터가 이번 폴백 — IDE·에이전트·launchd 처럼 로그인 셸을 안 거친
    # 실행은 LANG 이 없거나 C.UTF-8 이라 예전엔 한국어 맥에서도 영어가 나왔다.
    ("LANG 없음 → 시스템언어 ko", UNSET, UNSET, UNSET, UNSET, "ko", "ko"),
    ("LANG=C.UTF-8 → 시스템언어 ko", UNSET, UNSET, UNSET, "C.UTF-8", "ko", "ko"),
    ("LANG=POSIX → 시스템언어 ja", UNSET, UNSET, UNSET, "POSIX", "ja", "ja"),
    ("지원하지 않는 로케일 → 시스템언어 zh", UNSET, UNSET, UNSET, "fr_FR.UTF-8", "zh", "zh"),
    ("UBS_LANG=en 은 시스템언어를 이긴다", "en", UNSET, UNSET, UNSET, "ko", "en"),
    ("LANG=en_US 도 시스템언어를 이긴다", UNSET, UNSET, UNSET, "en_US.UTF-8", "ko", "en"),
]


class DetectLangTests(unittest.TestCase):
    def test_table(self) -> None:
        for desc, ubs_lang, lc_all, lc_messages, lang, system_lang, expected in CASES:
            row = dict(zip(_ENV_NAMES, (ubs_lang, lc_all, lc_messages, lang)))
            overrides = {name: value for name, value in row.items() if value is not UNSET}
            removed = [name for name, value in row.items() if value is UNSET]
            with self.subTest(desc):
                with mock.patch.dict(os.environ, overrides, clear=False), \
                        mock.patch.object(i18n, "_system_lang", return_value=system_lang):
                    for name in removed:
                        os.environ.pop(name, None)
                    actual = i18n._detect_lang()
                    self.assertEqual(
                        actual, expected,
                        f"[{desc}] 기대={expected!r} 실제={actual!r} "
                        f"(env={row} system={system_lang!r})",
                    )

    def test_system_lang_is_not_consulted_when_env_is_usable(self) -> None:
        """env 가 지원 언어를 주면 `defaults` 서브프로세스를 아예 띄우지 않는다."""
        with mock.patch.dict(os.environ, {"UBS_LANG": "ko"}, clear=False), \
                mock.patch.object(i18n, "_system_lang") as system_lang:
            self.assertEqual(i18n._detect_lang(), "ko")
            system_lang.assert_not_called()

    def test_system_lang_off_darwin(self) -> None:
        with mock.patch.object(i18n.sys, "platform", "linux"):
            self.assertIsNone(i18n._system_lang())

    def test_system_lang_parses_apple_locale(self) -> None:
        completed = subprocess.CompletedProcess([], 0, stdout="ko_KR\n", stderr="")
        with mock.patch.object(i18n.sys, "platform", "darwin"), \
                mock.patch.object(i18n.subprocess, "run", return_value=completed):
            self.assertEqual(i18n._system_lang(), "ko")

    def test_system_lang_unsupported_apple_locale(self) -> None:
        completed = subprocess.CompletedProcess([], 0, stdout="fr_FR\n", stderr="")
        with mock.patch.object(i18n.sys, "platform", "darwin"), \
                mock.patch.object(i18n.subprocess, "run", return_value=completed):
            self.assertIsNone(i18n._system_lang())

    def test_system_lang_survives_a_failing_defaults(self) -> None:
        for error in (OSError("no defaults"), subprocess.TimeoutExpired("defaults", 2)):
            with self.subTest(type(error).__name__):
                with mock.patch.object(i18n.sys, "platform", "darwin"), \
                        mock.patch.object(i18n.subprocess, "run", side_effect=error):
                    self.assertIsNone(i18n._system_lang())


if __name__ == "__main__":
    unittest.main()
