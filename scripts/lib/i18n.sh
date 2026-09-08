# CLI message catalog runtime. Not standalone-safe — do not source from install.sh.
#
# Language resolution: $UBS_LANG > $LC_ALL > $LC_MESSAGES > $LANG > macOS
# system language > en.
# Supported: ko en ja zh. Anything else (including "C"/"POSIX") falls through to
# the next step. See scripts/i18n.py for why the macOS step exists — the two
# implementations must stay in lockstep.

_UBS_I18N_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_UBS_I18N_DIR/i18n_messages.sh"

# Mirror scripts/i18n.py's _normalize: strip to the first segment before "."
# or "_", lowercase. The caller exact-matches — not a prefix glob — so e.g.
# "kok_IN.UTF-8" (Konkani) doesn't get misread as "ko".
ubs_normalize_lang() {
  local code="${1%%.*}"
  code="${code%%_*}"
  printf '%s' "$code" | tr '[:upper:]' '[:lower:]'
}

# Prints the macOS system language, or nothing off macOS / when unsupported.
# Tests override this function to keep the table independent of the host.
ubs_system_lang() {
  [ "$(uname -s 2>/dev/null)" = Darwin ] || return 0
  command -v defaults >/dev/null 2>&1 || return 0
  local raw
  raw="$(defaults read -g AppleLocale 2>/dev/null)" || return 0
  local code
  code="$(ubs_normalize_lang "$raw")"
  case "$code" in
    ko|en|ja|zh) printf '%s' "$code" ;;
  esac
}

ubs_detect_lang() {
  local raw code
  for raw in "${UBS_LANG:-}" "${LC_ALL:-}" "${LC_MESSAGES:-}" "${LANG:-}"; do
    code="$(ubs_normalize_lang "$raw")"
    case "$code" in
      ko|en|ja|zh) echo "$code"; return ;;
    esac
  done
  local system
  system="$(ubs_system_lang)"
  echo "${system:-en}"
}

UBS_LANG_RESOLVED="$(ubs_detect_lang)"

# ubs_msg KEY [printf-args...]
# Looks up UBS_MSG_<lang>_<KEY>, falls back to UBS_MSG_en_<KEY>, then to KEY itself.
# Prints without a trailing newline (call sites keep using echo/echo -e for that).
ubs_msg() {
  local key="$1"; shift
  local template
  eval "template=\"\${UBS_MSG_${UBS_LANG_RESOLVED}_${key}:-}\""
  if [ -z "$template" ]; then
    eval "template=\"\${UBS_MSG_en_${key}:-}\""
  fi
  [ -n "$template" ] || template="$key"
  if [ "$#" -gt 0 ]; then
    printf -- "$template" "$@"
  else
    printf '%s' "$template"
  fi
}
