#!/bin/zsh
#
# Checks that every entry in Localizable.xcstrings carries a non-empty translation in each of the
# seven non-source locales. The catalog is hand-maintained and nothing else verifies it, so a
# missing translation ships as English in that language with no signal.
#
# SCOPE, stated so nobody reads more into a green run: this is CATALOG COMPLETENESS only. It
# cannot see a localized string the source never put in the catalog. That half is uncovered by
# construction — `SettingRow` takes a `String` title (its identity for settings search) and
# localizes at runtime, so the toolchain's extractor cannot see those literals. "Localization is
# verified" would be false; "every catalog entry has its translations" is what this proves.
#
# Usage: Scripts/check-localizations.sh [catalog path]
#
# The seven are the non-source locales. It deliberately does NOT assert "exactly seven
# localizations": five entries legitimately carry an explicit `en` override, and a count check
# would fail on a correct catalog.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="${1:-$ROOT/OpenSuperWhisper/Localizable.xcstrings}"
PROJECT="${2:-$ROOT/OpenSuperWhisper.xcodeproj/project.pbxproj}"

[[ -f "$CATALOG" ]] || { echo "check-localizations: no catalog at $CATALOG" >&2; exit 2; }
[[ -f "$PROJECT" ]] || { echo "check-localizations: no project at $PROJECT" >&2; exit 2; }

python3 - "$CATALOG" "$PROJECT" <<'PY'
import json
import sys

path = sys.argv[1]
project = sys.argv[2]
KNOWN_KEY = "Recognition"

try:
    with open(path, encoding="utf-8") as handle:
        catalog = json.load(handle)
except (OSError, ValueError) as error:
    sys.exit(f"check-localizations: cannot read {path}: {error}")

# Which locales to require comes from the project's knownRegions, not from a list here. A region
# added to the project but not to this script would leave that language silently unchecked while
# the run still reported success — a check that passes on an input it never looked at.
source_language = catalog.get("sourceLanguage") or "en"
regions = []
inside = False
try:
    with open(project, encoding="utf-8") as handle:
        for line in handle:
            if "knownRegions = (" in line:
                inside = True
                continue
            if inside:
                if line.strip().startswith(")"):
                    break
                value = line.strip().rstrip(",").strip().strip('"')
                if value:
                    regions.append(value)
except OSError as error:
    sys.exit(f"check-localizations: cannot read {project}: {error}")

# "Base" is the development-region placeholder, not a translation; the source language needs no
# translation either.
locales = [r for r in regions if r not in ("Base", source_language)]
if not locales:
    sys.exit("check-localizations: no target locales found in knownRegions — the parse or the "
             "project moved, and an empty locale list would check nothing")

strings = catalog.get("strings")
# Positive controls. A completeness check that passes on an empty or mis-read catalog is worse
# than no check at all: it reports success for an input it never parsed.
if not isinstance(strings, dict) or not strings:
    sys.exit(f"check-localizations: no entries parsed from {path}")
if KNOWN_KEY not in strings:
    sys.exit(f'check-localizations: known key "{KNOWN_KEY}" not found — the schema moved, or the '
             f'wrong file is being read')

problems = []
for key, entry in strings.items():
    localizations = entry.get("localizations") or {}
    for locale in locales:
        unit = (localizations.get(locale) or {}).get("stringUnit") or {}
        value = (unit.get("value") or "").strip()
        if not value:
            state = "missing" if locale not in localizations else "empty"
            problems.append(f"  {locale}: {key!r} ({state})")

if problems:
    print(f"check-localizations: {len(problems)} incomplete translation(s) in {path}")
    print("\n".join(problems[:50]))
    if len(problems) > 50:
        print(f"  … and {len(problems) - 50} more")
    sys.exit(1)

print(f"check-localizations: {len(strings)} entries × {len(locales)} locales, all translated")
PY
