#!/usr/bin/env bash

# scripts/lib/i18n.sh의 ubs_detect_lang 자체에 대한 표 기반 단위 테스트(#60).
# LC_ALL > LC_MESSAGES > LANG 폴백 체인, UBS_LANG 최우선, prefix 매칭,
# 미지원 값 처리, 그리고 env 가 쓸 값을 주지 못할 때의 macOS 시스템 언어
# 폴백을 검증한다. 시스템 조회(ubs_system_lang)는 항상 덮어쓴다 — 실제
# 호스트의 언어 설정에 따라 결과가 달라지면 표가 의미를 잃는다. python 쪽(_detect_lang)의 동일한 표는
# tests/test_i18n_detect_lang.py에 있다 — 두 알고리즘이 지금 다르게 구현돼
# 있을 수 있는 문제(#54)는 별도이므로 여기서는 bash 구현 자체가 기대 동작을
# 만족하는지만 본다.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$ROOT/scripts/lib/i18n.sh" >/dev/null

FAILED=false

# 실제 macOS 설정을 읽지 않도록 시스템 조회를 표가 지정한 값으로 대체한다.
# "NONE"이면 macOS가 아니거나 지원하지 않는 언어인 경우와 같다(빈 출력).
FAKE_SYSTEM_LANG=NONE
ubs_system_lang() {
  [ "$FAKE_SYSTEM_LANG" = NONE ] || printf '%s' "$FAKE_SYSTEM_LANG"
}

# 값이 "UNSET"이면 해당 환경변수를 완전히 unset한다(빈 문자열과는 구분해서
# 취급됨을 검증하기 위함).
run_case() {
  local desc="$1" ubs_lang="$2" lc_all="$3" lc_messages="$4" lang="$5" system="$6" expected="$7"

  if [ "$ubs_lang" = UNSET ]; then unset UBS_LANG; else export UBS_LANG="$ubs_lang"; fi
  if [ "$lc_all" = UNSET ]; then unset LC_ALL; else export LC_ALL="$lc_all"; fi
  if [ "$lc_messages" = UNSET ]; then unset LC_MESSAGES; else export LC_MESSAGES="$lc_messages"; fi
  if [ "$lang" = UNSET ]; then unset LANG; else export LANG="$lang"; fi
  FAKE_SYSTEM_LANG="$system"

  local actual
  actual="$(ubs_detect_lang)"
  if [ "$actual" != "$expected" ]; then
    echo "[$desc] 기대=$expected 실제=$actual" \
      "(UBS_LANG=$ubs_lang LC_ALL=$lc_all LC_MESSAGES=$lc_messages LANG=$lang system=$system)" >&2
    FAILED=true
  fi
}

#                                          UBS_  LC_ALL      LC_MESSAGES LANG        system 기대
run_case "UBS_LANG=ko"                     ko    UNSET       UNSET       UNSET       NONE   ko
run_case "LANG만 ja_JP.UTF-8"               UNSET UNSET       UNSET       ja_JP.UTF-8 NONE   ja
run_case "LANG=C + 시스템언어 없음이면 en"  UNSET UNSET       UNSET       C           NONE   en
run_case "아무것도 없으면 en"               UNSET UNSET       UNSET       UNSET       NONE   en
run_case "지원하지 않는 로케일은 en"        UNSET UNSET       UNSET       fr_FR.UTF-8 NONE   en
run_case "UBS_LANG이 LANG보다 우선"         en    UNSET       UNSET       ko_KR.UTF-8 NONE   en
run_case "LC_ALL이 LANG보다 우선"           UNSET zh_CN.UTF-8 UNSET       ko_KR.UTF-8 NONE   zh
run_case "LC_MESSAGES가 LANG보다 우선"      UNSET UNSET       ja_JP.UTF-8 ko_KR.UTF-8 NONE   ja
run_case "LC_ALL이 LC_MESSAGES보다 우선"    UNSET zh_TW.UTF-8 ja_JP.UTF-8 ko_KR.UTF-8 NONE   zh
run_case "LANG=zh_CN.UTF-8"                 UNSET UNSET       UNSET       zh_CN.UTF-8 NONE   zh
run_case "LANG=en_US.UTF-8"                 UNSET UNSET       UNSET       en_US.UTF-8 NONE   en
run_case "UBS_LANG 빈 문자열은 미설정 취급" ""    UNSET       UNSET       ja_JP.UTF-8 NONE   ja
# 아래부터가 이번 폴백 — IDE·에이전트·launchd 처럼 로그인 셸을 안 거친 실행은
# LANG 이 없거나 C.UTF-8 이라 예전엔 한국어 맥에서도 영어가 나왔다.
run_case "LANG 없음 → 시스템언어 ko"        UNSET UNSET       UNSET       UNSET       ko     ko
run_case "LANG=C.UTF-8 → 시스템언어 ko"     UNSET UNSET       UNSET       C.UTF-8     ko     ko
run_case "LANG=POSIX → 시스템언어 ja"       UNSET UNSET       UNSET       POSIX       ja     ja
run_case "미지원 로케일 → 시스템언어 zh"    UNSET UNSET       UNSET       fr_FR.UTF-8 zh     zh
run_case "UBS_LANG=en 이 시스템언어를 이김" en    UNSET       UNSET       UNSET       ko     en
run_case "LANG=en_US 가 시스템언어를 이김"  UNSET UNSET       UNSET       en_US.UTF-8 ko     en

unset UBS_LANG LC_ALL LC_MESSAGES LANG 2>/dev/null || true

if [ "$FAILED" = true ]; then
  echo "ubs_detect_lang 표 기반 테스트 실패" >&2
  exit 1
fi

echo "ubs_detect_lang 단위 테스트 통과"
