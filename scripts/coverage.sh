#!/usr/bin/env bash
# Runs the unit tests with code coverage and prints line coverage per file and
# in total (same exclusions as the CI report). Extra arguments go to
# xcodebuild, e.g. -only-testing:ShellTests/ThemeTests.
#   ./scripts/coverage.sh                # whole suite
#   FILTER=UI/Claude ./scripts/coverage.sh   # only list files matching FILTER
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RESULT="build/Coverage.xcresult"
rm -rf "$RESULT"
mkdir -p build

set -o pipefail
xcodebuild test \
  -project Shell.xcodeproj -scheme Shell -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -resultBundlePath "$RESULT" \
  -enableCodeCoverage YES \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  "$@" 2>&1 | tee build/coverage.log \
  | grep -E '^/.*error:|error: |Test Case .* failed|Executed [0-9]+ tests|\*\* (TEST|BUILD) (SUCCEEDED|FAILED) \*\*' || true

if [[ ! -d $RESULT ]] || ! xcrun xccov view --report --json "$RESULT" > build/coverage.json 2>/dev/null; then
  echo "error: no coverage data; the build or test run failed (see build/coverage.log)" >&2
  exit 1
fi
FILTER="${FILTER:-}" python3 -c '
import json, os, re, sys
report = json.load(sys.stdin)
exclude = re.compile(r"/Tests/|Tests?\.swift$")
needle = os.environ.get("FILTER", "")
seen, rows, covered, executable = set(), [], 0, 0
for target in report.get("targets", []):
    for f in target.get("files", []):
        path = f["path"]
        if exclude.search(path) or path in seen:
            continue
        seen.add(path)
        c, e = f.get("coveredLines", 0), f.get("executableLines", 0)
        covered += c; executable += e
        rel = path.split("/Sources/")[-1]
        if needle in rel:
            rows.append((e - c, c, e, rel))
for missed, c, e, rel in sorted(rows, reverse=True):
    print(f"{100 * c / e if e else 100:6.1f}%  {c:5d}/{e:5d}  {rel}")
if executable:
    print(f"TOTAL  {100 * covered / executable:.2f}%  ({covered}/{executable} lines)")
' < build/coverage.json
xcrun xcresulttool get test-results summary --path "$RESULT" --compact 2>/dev/null | python3 -c '
import json, sys
s = json.load(sys.stdin)
print("TESTS  %s: %d passed, %d failed, %d skipped" % (s.get("result"), s.get("passedTests", 0), s.get("failedTests", 0), s.get("skippedTests", 0)))
' || true
