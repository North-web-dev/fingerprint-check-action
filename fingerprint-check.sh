#!/usr/bin/env bash
#
# fingerprint-check.sh — core of the fingerprint-check-action.
#
# Reads the fingerprint a reflector observed from an HTTP client (either the
# client driven by the user-supplied `run` command, or plain curl) and asserts
# that it still matches an expected browser profile. Exits non-zero on mismatch
# when fail-on-mismatch is true.
#
# Depends only on bash, curl and jq — all preinstalled on GitHub-hosted runners.
set -euo pipefail

# ---- tiny helpers ----------------------------------------------------------
die()  { printf '::error::%s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }
group_start() { printf '::group::%s\n' "$*"; }
group_end()   { printf '::endgroup::\n'; }

command -v jq   >/dev/null 2>&1 || die "jq is required but not found on the runner."
command -v curl >/dev/null 2>&1 || die "curl is required but not found on the runner."

REFLECTOR="${INPUT_REFLECTOR:?reflector input missing}"
RUN_CMD="${INPUT_RUN:-}"
EXPECT_PROFILE="${INPUT_EXPECT_PROFILE:-}"
EXPECT_JA4="${INPUT_EXPECT_JA4:-}"
EXPECT_JA3_HASH="${INPUT_EXPECT_JA3_HASH:-}"
EXPECT_AKAMAI_H2="${INPUT_EXPECT_AKAMAI_H2:-}"
FIELDS="${INPUT_FIELDS:-ja4}"
FAIL_ON_MISMATCH="${INPUT_FAIL_ON_MISMATCH:-true}"
PROFILES_URL="${INPUT_PROFILES_URL:-}"

# Normalise the fields list -> space separated, lowercased, de-whitespaced.
FIELDS_NORM="$(printf '%s' "$FIELDS" | tr 'A-Z,' 'a-z ' | tr -s ' ' | sed 's/^ //;s/ $//')"
[ -n "$FIELDS_NORM" ] || FIELDS_NORM="ja4"
for f in $FIELDS_NORM; do
  case "$f" in
    ja4|ja3_hash|akamai_h2) : ;;
    *) die "Unknown field '$f' in 'fields'. Allowed: ja4, ja3_hash, akamai_h2." ;;
  esac
done

# ---- 1. obtain the observed fingerprint JSON -------------------------------
group_start "Observe fingerprint"
RAW=""
if [ -n "$RUN_CMD" ]; then
  note "Running user command to reach the reflector:"
  note "  $RUN_CMD"
  # Export reflector so the command can reference $FP_REFLECTOR.
  export FP_REFLECTOR="$REFLECTOR"
  if ! RAW="$(bash -c "$RUN_CMD")"; then
    group_end
    die "The 'run' command exited non-zero."
  fi
else
  note "No 'run' command given — fetching the reflector with plain curl."
  note "  (curl is NOT a browser, so expect a mismatch when asserting a browser profile.)"
  if ! RAW="$(curl -fsSL --max-time 30 "$REFLECTOR")"; then
    group_end
    die "curl could not reach the reflector: $REFLECTOR"
  fi
fi

# The command/curl is expected to print the reflector's JSON. Be lenient: if the
# whole stdout isn't valid JSON, try to carve out the first balanced JSON object
# (handles a command that also prints its own log lines around the response).
if ! printf '%s' "$RAW" | jq -e . >/dev/null 2>&1; then
  EXTRACT=""
  if command -v python3 >/dev/null 2>&1; then
    EXTRACT="$(printf '%s' "$RAW" | python3 -I -c '
import sys, json
s = sys.stdin.read()
dec = json.JSONDecoder()
i = s.find("{")
while i != -1:
    try:
        obj, _ = dec.raw_decode(s, i)
        sys.stdout.write(json.dumps(obj))
        break
    except ValueError:
        i = s.find("{", i + 1)
' 2>/dev/null || true)"
  fi
  if [ -n "$EXTRACT" ] && printf '%s' "$EXTRACT" | jq -e . >/dev/null 2>&1; then
    RAW="$EXTRACT"
  else
    note "----- captured output (not valid JSON) -----"
    printf '%s\n' "$RAW" | head -c 2000
    note ""
    note "--------------------------------------------"
    group_end
    die "Could not parse a JSON fingerprint from the output. The command must print the reflector's JSON response to stdout."
  fi
fi

OBS_JA4="$(printf '%s' "$RAW"      | jq -r '.ja4 // ""')"
OBS_JA3_HASH="$(printf '%s' "$RAW" | jq -r '.ja3_hash // ""')"
# reflector calls it akamai_h2; accept a couple of aliases defensively.
OBS_AKAMAI="$(printf '%s' "$RAW"   | jq -r '.akamai_h2 // .akamai // .akamai_fingerprint // ""')"
OBS_UA="$(printf '%s' "$RAW"       | jq -r '.user_agent // .["user-agent"] // ""')"

note "observed ja4       : ${OBS_JA4:-<none>}"
note "observed ja3_hash  : ${OBS_JA3_HASH:-<none>}"
note "observed akamai_h2 : ${OBS_AKAMAI:-<none>}"
note "observed user-agent: ${OBS_UA:-<none>}"
group_end

# ---- 2. resolve expected values --------------------------------------------
group_start "Resolve expected profile"
if [ -n "$EXPECT_PROFILE" ]; then
  note "Resolving profile '$EXPECT_PROFILE' from: $PROFILES_URL"
  DB="$(curl -fsSL --max-time 30 "$PROFILES_URL")" || die "Could not fetch profiles DB: $PROFILES_URL"
  printf '%s' "$DB" | jq -e --arg p "$EXPECT_PROFILE" '.browsers[$p]' >/dev/null 2>&1 \
    || die "Profile '$EXPECT_PROFILE' not found in the DB. Available: $(printf '%s' "$DB" | jq -r '.browsers | keys | join(", ")')"
  DB_JA4="$(printf '%s' "$DB"      | jq -r --arg p "$EXPECT_PROFILE" '.browsers[$p].tls.ja4 // ""')"
  DB_JA3_HASH="$(printf '%s' "$DB" | jq -r --arg p "$EXPECT_PROFILE" '.browsers[$p].tls.ja3_hash // ""')"
  DB_AKAMAI="$(printf '%s' "$DB"   | jq -r --arg p "$EXPECT_PROFILE" '.browsers[$p].http2.akamai_fingerprint // ""')"
  note "profile ja4      : $DB_JA4"
  note "profile ja3_hash : $DB_JA3_HASH"
  note "profile akamai   : $DB_AKAMAI"
else
  DB_JA4=""; DB_JA3_HASH=""; DB_AKAMAI=""
fi

# Explicit inputs win over the looked-up profile values.
EXP_JA4="${EXPECT_JA4:-$DB_JA4}"
EXP_JA3_HASH="${EXPECT_JA3_HASH:-$DB_JA3_HASH}"
EXP_AKAMAI="${EXPECT_AKAMAI_H2:-$DB_AKAMAI}"
group_end

# ---- 3. compare ------------------------------------------------------------
group_start "Assert fields: $FIELDS_NORM"
MATCH="true"
SUMMARY=""

compare_field() {
  local label="$1" observed="$2" expected="$3"
  if [ -z "$expected" ]; then
    die "Field '$label' is asserted but no expected value was provided (set expect-profile or the matching expect-* input)."
  fi
  if [ "$observed" = "$expected" ]; then
    note "✅ $label matches"
    note "   observed = $observed"
    SUMMARY="${SUMMARY}| \`$label\` | ✅ match | \`$observed\` |"$'\n'
  else
    note "❌ $label MISMATCH"
    note "   expected = $expected"
    note "   observed = ${observed:-<none>}"
    MATCH="false"
    SUMMARY="${SUMMARY}| \`$label\` | ❌ mismatch | expected \`$expected\`, got \`${observed:-<none>}\` |"$'\n'
  fi
}

for f in $FIELDS_NORM; do
  case "$f" in
    ja4)        compare_field "ja4"        "$OBS_JA4"      "$EXP_JA4" ;;
    ja3_hash)   compare_field "ja3_hash"   "$OBS_JA3_HASH" "$EXP_JA3_HASH" ;;
    akamai_h2)  compare_field "akamai_h2"  "$OBS_AKAMAI"   "$EXP_AKAMAI" ;;
  esac
done
group_end

# ---- 4. outputs + job summary ----------------------------------------------
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "ja4=$OBS_JA4"
    echo "ja3_hash=$OBS_JA3_HASH"
    echo "akamai_h2=$OBS_AKAMAI"
    echo "user_agent=$OBS_UA"
    echo "match=$MATCH"
  } >> "$GITHUB_OUTPUT"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Fingerprint check"
    echo ""
    echo "Reflector: \`$REFLECTOR\`  "
    [ -n "$EXPECT_PROFILE" ] && echo "Expected profile: \`$EXPECT_PROFILE\`  "
    echo "Overall match: **$MATCH**"
    echo ""
    echo "| Field | Result | Detail |"
    echo "|---|---|---|"
    printf '%s' "$SUMMARY"
  } >> "$GITHUB_STEP_SUMMARY"
fi

# ---- 5. exit ---------------------------------------------------------------
if [ "$MATCH" = "true" ]; then
  note "Result: MATCH ✅"
  exit 0
fi

if [ "$FAIL_ON_MISMATCH" = "true" ]; then
  die "Fingerprint MISMATCH — the client no longer looks like the expected browser profile. (set fail-on-mismatch: false to make this non-fatal)"
fi
note "::warning::Fingerprint MISMATCH — continuing because fail-on-mismatch is false."
exit 0
