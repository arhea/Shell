#!/usr/bin/env bash
# Creates or updates the issue and PR labels on GitHub. Safe to re-run.
#
#   ./scripts/labels.sh [owner/repo]     (default: arhea/Shell)
#
# Type labels (exactly one per issue) match the title prefixes bug:,
# feature:, chore:, docs: and question:. Priority labels p1-p3 are added at
# triage. See .claude/skills/github-issues/SKILL.md.
set -euo pipefail
REPO="${1:-arhea/Shell}"

# Rename GitHub's defaults so existing issues keep their label.
rename() {
    if gh label list --repo "$REPO" --limit 200 --json name --jq '.[].name' | grep -qx "$1"; then
        gh label edit "$1" --repo "$REPO" --name "$2"
    fi
}
rename enhancement feature
rename documentation docs

label() { gh label create "$1" --repo "$REPO" --color "$2" --description "$3" --force; }

# Type
label bug          d73a4a "Shell doesn't behave as it should"
label feature      a2eeef "New capability or a meaningful change to one"
label chore        ededed "Refactor, tech debt, build, CI, tests or dependencies; no user-visible change"
label docs         0075ca "Missing, wrong or unclear documentation"
label question     d876e3 "Needs an answer or a decision"

# Priority
label p1           b60205 "P1: broken core workflow, crash, data loss or regression. Fix next."
label p2           fbca04 "P2: important; degraded with a workaround. Planned soon."
label p3           c2e0c6 "P3: minor or nice to have. When time allows."

# Workflow
label needs-triage fef2c0 "Needs a type and priority from a maintainer"
label "good first issue" 7057ff "Well scoped, with clear acceptance criteria and code pointers"
label "help wanted" 008672 "The maintainer would welcome a contributor on this"
