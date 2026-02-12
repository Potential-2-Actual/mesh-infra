#!/bin/bash
# preflight.sh — Pre-flight validation before starting implementation work
# Usage: ./scripts/preflight.sh POT-XXX
# Exit 0 = pass, Exit 1 = fail
#
# Checks:
# 1. Linear issue exists and has description (AC)
# 2. Decision Log queried for relevant category
# 3. Branch naming follows convention

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

ISSUE_REF="${1:-}"
PASS=0
FAIL=0
WARN=0

pass() { echo -e "${GREEN}✅ $1${NC}"; ((PASS++)); }
fail() { echo -e "${RED}❌ $1${NC}"; ((FAIL++)); }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; ((WARN++)); }

echo "🛫 Pre-flight check"
echo "==================="

# 1. Linear issue reference provided
if [ -z "$ISSUE_REF" ]; then
  fail "No Linear issue reference provided. Usage: preflight.sh POT-XXX"
  echo -e "\n${RED}Pre-flight FAILED${NC} (${FAIL} failed)"
  exit 1
fi

echo -e "\nChecking $ISSUE_REF..."

# 2. Linear issue exists
ISSUE_DATA=$(mcporter call linear.search_issues query="$ISSUE_REF" 2>/dev/null || echo "[]")
ISSUE_COUNT=$(echo "$ISSUE_DATA" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [ "$ISSUE_COUNT" -gt 0 ]; then
  ISSUE_ID=$(echo "$ISSUE_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])" 2>/dev/null)
  ISSUE_TITLE=$(echo "$ISSUE_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['title'])" 2>/dev/null)
  ISSUE_STATUS=$(echo "$ISSUE_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['status'])" 2>/dev/null)
  pass "Linear issue found: $ISSUE_TITLE ($ISSUE_STATUS)"
  
  # Check for description (AC)
  FULL_ISSUE=$(mcporter call linear.get_issue issueId="$ISSUE_ID" 2>/dev/null || echo "{}")
  DESC=$(echo "$FULL_ISSUE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('description',''))" 2>/dev/null || echo "")
  if [ -n "$DESC" ] && [ ${#DESC} -gt 20 ]; then
    pass "Issue has description/AC (${#DESC} chars)"
  else
    fail "Issue has no description or AC — add Gherkin acceptance criteria"
  fi
else
  fail "Linear issue $ISSUE_REF not found"
fi

# 3. Branch naming (if in a git repo)
if git rev-parse --git-dir > /dev/null 2>&1; then
  BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "detached")
  case "$BRANCH" in
    main|develop|release/*|hotfix/*)
      warn "On $BRANCH — create a feature branch first"
      ;;
    *)
      if echo "$BRANCH" | grep -qiE 'POT-[0-9]+'; then
        pass "Branch naming OK: $BRANCH"
      else
        fail "Branch '$BRANCH' missing POT-XXX reference"
      fi
      ;;
  esac
else
  warn "Not in a git repo — skipping branch check"
fi

# 4. Decision Log check reminder
echo -e "\n📋 Decision Log reminder:"
echo "   Query the Decision Log in Notion before implementing."
echo "   DB: https://www.notion.so/2df915b43892477880c3f3475e1efd6a"
warn "Decision Log check is manual — review relevant Active decisions"

# 5. CHECKLIST.md reminder
if [ -f "$(dirname "$0")/../CHECKLIST.md" ]; then
  pass "CHECKLIST.md exists in workspace"
else
  warn "CHECKLIST.md not found in workspace"
fi

# Summary
echo -e "\n==================="
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${WARN} warnings${NC}"

if [ "$FAIL" -gt 0 ]; then
  echo -e "${RED}Pre-flight FAILED${NC} — fix issues before starting work"
  exit 1
else
  echo -e "${GREEN}Pre-flight PASSED${NC} — ready to implement"
  exit 0
fi
