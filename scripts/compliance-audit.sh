#!/bin/bash
# compliance-audit.sh — Weekly process compliance scoring
# Usage: ./scripts/compliance-audit.sh [days=7]
# Audits PRs across mesh repos and reports adherence metrics.

set -uo pipefail

DAYS="${1:-7}"
SINCE=$(date -d "$DAYS days ago" --iso-8601 2>/dev/null || date -v-${DAYS}d +%Y-%m-%d)
REPOS=("Potential-2-Actual/mesh-infra" "Potential-2-Actual/mesh-dashboard" "Potential-2-Actual/openclaw-nats")

TOTAL_PRS=0
PRS_WITH_REF=0
PRS_REVIEWED=0
PRS_NAMING_OK=0
DETAILS=""

for REPO in "${REPOS[@]}"; do
  # Get merged PRs from the past N days
  PRS=$(gh pr list --repo "$REPO" --state merged --json number,title,headRefName,reviews,mergedAt \
    --jq "[.[] | select(.mergedAt >= \"${SINCE}T00:00:00Z\")]" 2>/dev/null || echo "[]")

  COUNT=$(echo "$PRS" | jq 'length' 2>/dev/null || echo "0")
  if [ "$COUNT" -eq 0 ]; then
    continue
  fi

  REPO_SHORT=$(echo "$REPO" | cut -d/ -f2)

  for i in $(seq 0 $((COUNT - 1))); do
    PR_NUM=$(echo "$PRS" | jq -r ".[$i].number")
    PR_TITLE=$(echo "$PRS" | jq -r ".[$i].title")
    BRANCH=$(echo "$PRS" | jq -r ".[$i].headRefName")
    REVIEW_COUNT=$(echo "$PRS" | jq ".[$i].reviews | length")

    ((TOTAL_PRS++))

    # Check 1: Linear issue reference in branch or title
    HAS_REF=false
    if echo "$BRANCH $PR_TITLE" | grep -qiE 'POT-[0-9]+'; then
      HAS_REF=true
      ((PRS_WITH_REF++))
    fi

    # Check 2: Cross-agent review
    HAS_REVIEW=false
    if [ "$REVIEW_COUNT" -gt 0 ]; then
      HAS_REVIEW=true
      ((PRS_REVIEWED++))
    fi

    # Check 3: Branch naming convention
    NAMING_OK=false
    case "$BRANCH" in
      feat/*|fix/*|chore/*|refactor/*|docs/*)
        NAMING_OK=true
        ((PRS_NAMING_OK++))
        ;;
      main|dependabot/*) 
        # Don't count main or dependabot against naming
        NAMING_OK=true
        ((PRS_NAMING_OK++))
        ;;
    esac

    # Build detail line
    REF_ICON=$( [ "$HAS_REF" = true ] && echo "✅" || echo "❌" )
    REV_ICON=$( [ "$HAS_REVIEW" = true ] && echo "✅" || echo "❌" )
    NAME_ICON=$( [ "$NAMING_OK" = true ] && echo "✅" || echo "❌" )
    DETAILS="${DETAILS}\n  ${REPO_SHORT}#${PR_NUM}: ${REF_ICON}ref ${REV_ICON}review ${NAME_ICON}naming — ${PR_TITLE}"
  done
done

# Calculate scores
if [ "$TOTAL_PRS" -gt 0 ]; then
  REF_PCT=$((PRS_WITH_REF * 100 / TOTAL_PRS))
  REV_PCT=$((PRS_REVIEWED * 100 / TOTAL_PRS))
  NAME_PCT=$((PRS_NAMING_OK * 100 / TOTAL_PRS))
  OVERALL=$(( (REF_PCT + REV_PCT + NAME_PCT) / 3 ))
else
  REF_PCT=0; REV_PCT=0; NAME_PCT=0; OVERALL=0
fi

# Load previous score for trend
SCORE_FILE="${HOME}/.openclaw/workspace/memory/compliance-scores.json"
TREND="—"
if [ -f "$SCORE_FILE" ]; then
  PREV_OVERALL=$(jq -r '.[-1].overall // 0' "$SCORE_FILE" 2>/dev/null || echo "0")
  if [ "$OVERALL" -gt "$PREV_OVERALL" ]; then
    TREND="📈 improving"
  elif [ "$OVERALL" -lt "$PREV_OVERALL" ]; then
    TREND="📉 declining"
  else
    TREND="➡️ stable"
  fi
fi

# Save score
mkdir -p "$(dirname "$SCORE_FILE")"
if [ -f "$SCORE_FILE" ]; then
  jq ". + [{\"date\": \"$(date --iso-8601)\", \"prs\": $TOTAL_PRS, \"refPct\": $REF_PCT, \"reviewPct\": $REV_PCT, \"namingPct\": $NAME_PCT, \"overall\": $OVERALL}]" "$SCORE_FILE" > "${SCORE_FILE}.tmp" && mv "${SCORE_FILE}.tmp" "$SCORE_FILE"
else
  echo "[{\"date\": \"$(date --iso-8601)\", \"prs\": $TOTAL_PRS, \"refPct\": $REF_PCT, \"reviewPct\": $REV_PCT, \"namingPct\": $NAME_PCT, \"overall\": $OVERALL}]" > "$SCORE_FILE"
fi

# Output report
REPORT="📊 **Process Compliance Report** (past ${DAYS} days)

**${TOTAL_PRS} PRs** across ${#REPOS[@]} repos

| Metric | Score |
|--------|-------|
| Linear issue ref | ${PRS_WITH_REF}/${TOTAL_PRS} (${REF_PCT}%) |
| Cross-agent review | ${PRS_REVIEWED}/${TOTAL_PRS} (${REV_PCT}%) |
| Branch naming | ${PRS_NAMING_OK}/${TOTAL_PRS} (${NAME_PCT}%) |
| **Overall** | **${OVERALL}%** ${TREND} |
$(echo -e "$DETAILS")"

echo "$REPORT"
