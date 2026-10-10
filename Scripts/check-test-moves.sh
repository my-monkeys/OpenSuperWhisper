#!/bin/zsh
#
# Checks the tests moved from the app-hosted suite to the core package (docs/core-extraction.md,
# slice 5) against the committed map, and optionally against the slice-4 reference.
#
# Usage: Scripts/check-test-moves.sh [--slice5] [--strict] [--hosted <run-tests list | xcresult>]
#            [--core-macos <xcresult>] [--core-ios <xcresult>] [--allow-absent <Class>]...
#
#   --hosted        results of the hosted suite: an .xcresult, or a list of
#                   "Test case 'Class.method()' status" lines
#   --core-macos    the .xcresult of `Scripts/test-core.sh macos`
#   --core-ios      the .xcresult of `Scripts/test-core.sh ios`
#   --slice5        also compare with the frozen slice-4 reference: every unmoved reference test
#                   still hosted, nothing hosted outside it, and the floors. Local only: the
#                   reference is a record of slice 4, so any later hosted test added, renamed or
#                   removed differs from it
#   --allow-absent  with --slice5, a hosted class that may be missing from --hosted
#   --strict        implies --slice5; hosted statuses must also equal the reference's
#
# Always checked, in CI too, because they hold whatever tests are added later: the map's shape,
# no failure in any input, no mapped old id back in the hosted suite, and every mapped new id
# present and passed (not skipped) in every core input. Renaming a moved core test means
# updating its new id in the map. The static rules on OpenSuperWhisperCore/Tests are always
# checked too. Every violation is printed, then a tally per input; the exit status is non-zero
# if there was any.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REFERENCE=docs/tests/hosted-slice4.txt
MAP=docs/test-moves-slice5.txt
HOSTED_TARGET=OpenSuperWhisperTests
CORE_TARGET=OpenSuperWhisperCoreTests
CORE_TESTS=OpenSuperWhisperCore/Tests
# XCTest classes in the core target that may derive from XCTestCase directly: the base class.
DIRECT_XCTESTCASE=(CoreTestCase)

strict=0 slice5=0 hosted="" core_macos="" core_ios=""
allow_absent=()
while (( $# )); do
  case "$1" in
    --strict) strict=1; slice5=1 ;;
    --slice5) slice5=1 ;;
    --hosted) hosted="$2"; shift ;;
    --core-macos) core_macos="$2"; shift ;;
    --core-ios) core_ios="$2"; shift ;;
    --allow-absent) allow_absent+=("$2"); shift ;;
    *) echo "usage: $0 [--slice5] [--strict] [--hosted X] [--core-macos X] [--core-ios X] [--allow-absent Class]..." >&2; exit 2 ;;
  esac
  shift
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
violations=0
violation() { echo "violation: $*"; violations=$((violations + 1)); }

# "Test case 'Class.method()' status" -> "<target>/Class/method() status"
normalise_list() {
  sed -nE "s/^Test case '([A-Za-z0-9_]+)\.([^']+)' (passed|failed|skipped)$/$2\/\1\/\2 \3/p" "$1"
}

# Every "Test Case" node under each "Unit test bundle", as "<bundle>/<nodeIdentifier> <result>".
# The node's result is already the final one when a test was retried. An expected failure counts
# as a failure: no test in the reference expects one.
normalise_xcresult() {
  xcrun xcresulttool get test-results tests --path "$1" | jq -r '
    .. | objects | select(.nodeType? == "Unit test bundle") | .name as $bundle
    | .. | objects | select(.nodeType? == "Test Case")
    | "\($bundle)/\(.nodeIdentifier) \(.result | ascii_downcase
        | if . == "expected failure" then "failed" else . end)"'
}

# Normalises an input into $WORK/<name>, one "id status" per id (the last line wins).
load() {
  local name=$1 file=$2 target=$3
  [[ -e $file ]] || { violation "$name: no such input: $file"; : > "$WORK/$name"; return; }
  if [[ -d $file ]]; then normalise_xcresult "$file"; else normalise_list "$file" "$target"; fi \
    | awk '{ status[$1] = $2 } END { for (id in status) print id, status[id] }' | sort > "$WORK/$name"
  [[ -s $WORK/$name ]] || violation "$name: no test results in $file"
  local bad
  bad="$(grep -vE ' (passed|skipped|failed)$' "$WORK/$name")"
  [[ -z $bad ]] || violation "$name: unknown status: $(echo "$bad" | head -3 | tr '\n' ';')"
}

tally() {
  printf '%-11s %4d results: %4d passed, %4d skipped, %4d failed\n' "$1" \
    "$(wc -l < "$WORK/$1")" "$(grep -c ' passed$' "$WORK/$1")" \
    "$(grep -c ' skipped$' "$WORK/$1")" "$(grep -c ' failed$' "$WORK/$1")"
}

# 1. The reference and the map.
normalise_list "$REFERENCE" "$HOSTED_TARGET" | sort > "$WORK/reference"
(( $(wc -l < "$WORK/reference") == $(wc -l < "$REFERENCE") )) \
  || violation "$REFERENCE has lines that are not \"Test case 'Class.method()' status\""
cut -d' ' -f1 "$WORK/reference" > "$WORK/reference-ids"
reference_count=$(wc -l < "$WORK/reference-ids" | tr -d ' ')

floor=$(sed -nE 's/^# floor: ([0-9]+)$/\1/p' "$MAP")
[[ -n $floor ]] || { violation "$MAP has no '# floor: N' line"; floor=0; }

: > "$WORK/map"
grep -vE '^(#|$)' "$MAP" | while IFS= read -r line; do
  if [[ $line =~ '^([^ ]+) -> ([^ ]+)$' ]]; then
    echo "${match[1]} ${match[2]}" >> "$WORK/map"
  else
    violation "map line is not '<old id> -> <new id>': $line"
  fi
done
cut -d' ' -f1 "$WORK/map" | sort > "$WORK/map-old"
cut -d' ' -f2 "$WORK/map" | sort > "$WORK/map-new"
for dup in $(uniq -d "$WORK/map-old"); do violation "map: old id listed twice: $dup"; done
for dup in $(uniq -d "$WORK/map-new"); do violation "map: new id listed twice: $dup"; done
for old in $(cat "$WORK/map-old"); do
  [[ $old == $HOSTED_TARGET/* ]] || violation "map: old id outside $HOSTED_TARGET: $old"
  grep -qxF "$old" "$WORK/reference-ids" || violation "map: old id not in the reference: $old"
done
for new in $(cat "$WORK/map-new"); do
  [[ $new == $CORE_TARGET/* ]] || violation "map: new id outside $CORE_TARGET: $new"
done

# 2. to 4. No failure, no moved test back in the hosted suite, and with --slice5 the hosted
# results against the reference minus the map.
[[ -n $hosted ]] && load hosted "$hosted" "$HOSTED_TARGET"
[[ -n $core_macos ]] && load core-macos "$core_macos" "$CORE_TARGET"
[[ -n $core_ios ]] && load core-ios "$core_ios" "$CORE_TARGET"

for input in hosted core-macos core-ios; do
  [[ -f $WORK/$input ]] || continue
  for id in $(awk '$2 == "failed" { print $1 }' "$WORK/$input"); do violation "$input: failed: $id"; done
done

if [[ -n $hosted ]]; then
  for old in $(cat "$WORK/map-old"); do
    grep -q "^$old " "$WORK/hosted" && violation "hosted: moved test still in the hosted suite: $old"
  done
fi

if [[ -n $hosted ]] && (( slice5 )); then
  while read -r id expected; do
    grep -qxF "$id" "$WORK/map-old" && continue
    actual="$(awk -v id="$id" '$1 == id { print $2 }' "$WORK/hosted")"
    if [[ -z $actual ]]; then
      class="$(echo "$id" | cut -d/ -f2)"
      (( ${allow_absent[(Ie)$class]} )) || violation "hosted: missing: $id"
    elif (( strict )) && [[ $actual != $expected ]]; then
      violation "hosted: $id is $actual, the reference says $expected"
    fi
  done < "$WORK/reference"
  for id in $(cut -d' ' -f1 "$WORK/hosted"); do
    grep -qxF "$id" "$WORK/reference-ids" || violation "hosted: not in the reference: $id"
  done
fi

# 5. Every moved test passes in every core input.
for input in core-macos core-ios; do
  [[ -f $WORK/$input ]] || continue
  for new in $(cat "$WORK/map-new"); do
    actual="$(awk -v id="$new" '$1 == id { print $2 }' "$WORK/$input")"
    if [[ -z $actual ]]; then
      violation "$input: moved test missing: $new"
    elif [[ $actual == skipped ]]; then
      violation "$input: moved test skipped: $new"
    fi
  done
done

# 6. With --slice5: the total only grows, and the core macOS run on its own keeps what the core
# added.
map_count=$(wc -l < "$WORK/map" | tr -d ' ')
core_floor=$(( floor - (reference_count - map_count) ))
if [[ -n $core_macos ]] && (( slice5 )); then
  core_count=$(wc -l < "$WORK/core-macos" | tr -d ' ')
  (( core_count >= core_floor )) \
    || violation "core macOS = $core_count results, below the core floor of $core_floor (floor $floor - $(( reference_count - map_count )) unmoved)"
fi
if [[ -n $hosted && -n $core_macos ]] && (( slice5 )); then
  total=$(( $(wc -l < "$WORK/hosted") + $(wc -l < "$WORK/core-macos") ))
  (( total >= floor )) || violation "hosted + core macOS = $total results, below the floor of $floor"
  (( total >= reference_count )) || violation "hosted + core macOS = $total results, below the reference's $reference_count"
fi

# 7. Static rules on the core tests.
for file in $(find "$CORE_TESTS" -name '*.swift'); do
  grep -nE '^[^/]*class +[A-Za-z0-9_]+ *: *XCTestCase\b' "$file" | while IFS= read -r hit; do
    class="$(echo "$hit" | sed -E 's/.*class +([A-Za-z0-9_]+).*/\1/')"
    (( ${DIRECT_XCTESTCASE[(Ie)$class]} )) || violation "$file: $class derives from XCTestCase, not CoreTestCase"
  done
  grep -nE '\bScratchPreferences\b' "$file" | while IFS= read -r hit; do violation "$file:$hit: ScratchPreferences"; done
  grep -nE 'Keychain\.(set\([^)]*for: *"|read\( *")' "$file" | while IFS= read -r hit; do
    violation "$file:$hit: fixed Keychain account (use core-tests-<UUID>)"
  done
  grep -nE '@testable +import +OpenSuperWhisper\b' "$file" | while IFS= read -r hit; do
    violation "$file:$hit: imports the app module"
  done
done

if (( slice5 )); then
  echo "reference   $reference_count results; map: $map_count moved tests; floor $floor, core floor $core_floor"
else
  echo "map: $map_count moved tests (no comparison with the slice-4 reference without --slice5)"
fi
for input in hosted core-macos core-ios; do [[ -f $WORK/$input ]] && tally $input; done
for input in core-macos core-ios; do
  [[ -f $WORK/$input ]] || continue
  awk -v input="$input" '$2 == "skipped" { print "skipped (" input "): " $1 }' "$WORK/$input"
done
if (( violations )); then
  echo "check-test-moves: $violations violation(s)"
  exit 1
fi
echo "check-test-moves: OK"
