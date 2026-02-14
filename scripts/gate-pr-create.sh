#!/bin/bash
# gate-pr-create.sh — Process gate: validates Linear issue before PR creation
# Usage: ./scripts/gate-pr-create.sh [gh pr create args...]
#
# Checks (reads from MESH-PROCESS-RULES KV when available):
# 1. Branch name contains POT-XXX reference
# 2. Linear issue exists
# 3. Linear issue is In Progress (warn if not)
# Then passes through to `gh pr create` with all original args.

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

LINEAR_TOKEN="${LINEAR_ACCESS_TOKEN:-}"

# 1. Extract POT-XXX from branch name
BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ -z "$BRANCH" ]; then
  echo -e "${RED}❌ Not on a branch (detached HEAD?)${NC}"
  exit 1
fi

ISSUE_REF=$(echo "$BRANCH" | grep -oiE 'POT-[0-9]+' | head -1 | tr '[:lower:]' '[:upper:]')
if [ -z "$ISSUE_REF" ]; then
  echo -e "${RED}❌ No POT-XX reference found in branch name '$BRANCH'${NC}"
  echo -e "   Branch should be like: feat/POT-170-my-feature"
  echo -e "   Rename with: git branch -m feat/${ISSUE_REF:-POT-XXX}-description"
  exit 1
fi

echo -e "${GREEN}✅ Branch references $ISSUE_REF${NC}"

# 2. Check Linear issue exists
if [ -z "$LINEAR_TOKEN" ]; then
  # Try sourcing from bashrc
  source ~/.bashrc 2>/dev/null
  LINEAR_TOKEN="${LINEAR_ACCESS_TOKEN:-}"
fi

if [ -n "$LINEAR_TOKEN" ]; then
  ISSUE_NUM=$(echo "$ISSUE_REF" | grep -oE '[0-9]+')
  RESULT=$(curl -s -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"query\": \"{ issues(filter: {number: {eq: $ISSUE_NUM}}, first: 1) { nodes { title state { name } } } }\"}" 2>/dev/null)

  TITLE=$(echo "$RESULT" | jq -r '.data.issues.nodes[0].title // empty' 2>/dev/null)
  STATE=$(echo "$RESULT" | jq -r '.data.issues.nodes[0].state.name // empty' 2>/dev/null)

  if [ -z "$TITLE" ]; then
    echo -e "${RED}❌ Linear issue $ISSUE_REF not found${NC}"
    echo -e "   Create it first: https://linear.app/potential2actual"
    exit 1
  fi

  echo -e "${GREEN}✅ $ISSUE_REF: $TITLE${NC}"

  if [ "$STATE" = "In Progress" ]; then
    echo -e "${GREEN}✅ Status: In Progress${NC}"
  elif [ "$STATE" = "In Review" ]; then
    echo -e "${GREEN}✅ Status: In Review${NC}"
  else
    echo -e "${YELLOW}⚠️  Status: $STATE (expected 'In Progress')${NC}"
    echo -e "   Proceeding anyway — consider updating the issue status."
  fi
else
  echo -e "${YELLOW}⚠️  LINEAR_ACCESS_TOKEN not set — skipping Linear validation${NC}"
fi

# 3. Pass through to gh pr create
echo -e "\n${GREEN}Gate passed — creating PR...${NC}\n"
exec gh pr create "$@"
