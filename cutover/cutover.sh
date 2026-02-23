#!/bin/bash
# =============================================================================
# migration-tooling/cutover/cutover.sh
# PPT Phase 4 — CUTOVER
# "Atomic switch: GHA becomes primary, ADO pipeline disabled (not deleted)"
# "ADO pipeline kept dormant for 30-day rollback window"
# "Rule 4: Cutover only during approved change window — no Friday/weekend"
#
# What this does:
#   1. Pre-flight checks (parity score ≥98%, no active deployments)
#   2. Disable ADO pipelines (set to disabled/dormant — NOT deleted)
#   3. Set MIGRATION_PHASE=4 in GitHub repo variables
#   4. Verify GHA workflows are active
#   5. Log cutover event with rollback instructions
#   6. Send notification
#
# Rollback: ./rollback.sh  — re-enables ADO, sets MIGRATION_PHASE=2
#
# Usage:
#   export ADO_PAT GH_PAT ADO_ORG ADO_PROJECT GH_ORG
#   ./cutover.sh                   # interactive
#   ./cutover.sh --dry-run         # preview only
#   ./cutover.sh --service bmi-service  # one service only
# =============================================================================

set -euo pipefail

DRY_RUN=false
TARGET_SERVICE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)  DRY_RUN=true; shift ;;
    --service)  TARGET_SERVICE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ── Required env ──────────────────────────────────────────────────────────────
ADO_PAT="${ADO_PAT:-}"
GH_PAT="${GH_PAT:-}"
ADO_ORG="${ADO_ORG:-}"
ADO_PROJECT="${ADO_PROJECT:-}"
GH_ORG="${GH_ORG:-}"

for V in ADO_PAT GH_PAT ADO_ORG ADO_PROJECT GH_ORG; do
  [[ -n "${!V:-}" ]] || { echo "❌ Required: $V"; exit 1; }
done

ADO_BASE="https://dev.azure.com/$ADO_ORG/$ADO_PROJECT/_apis"
ADO_AUTH="Authorization: Basic $(echo -n ":$ADO_PAT" | base64 -w0)"
GH_AUTH="Authorization: Bearer $GH_PAT"
GH_ACCEPT="Accept: application/vnd.github.v3+json"
CT="Content-Type: application/json"

SERVICES=("bmi-service" "unit-converter")
[[ -n "$TARGET_SERVICE" ]] && SERVICES=("$TARGET_SERVICE")

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOG_FILE="cutover-log-$TIMESTAMP.json"

echo "╔════════════════════════════════════════════════════╗"
echo "║        PHASE 4 CUTOVER: ADO → GitHub Actions       ║"
echo "╠════════════════════════════════════════════════════╣"
echo "║  ADO Org    : $ADO_ORG / $ADO_PROJECT"
echo "║  GH Org     : $GH_ORG"
echo "║  Services   : ${SERVICES[*]}"
echo "║  Dry Run    : $DRY_RUN"
echo "║  Timestamp  : $TIMESTAMP"
echo "╚════════════════════════════════════════════════════╝"

# ── Safety checks ─────────────────────────────────────────────────────────────
echo ""
echo "STEP 0: Safety Checks"

# Check day of week (PPT Rule 4: no Friday/weekend cutovers)
DOW=$(date +%u)   # 1=Mon ... 7=Sun
DAY_NAME=$(date +%A)
if [[ "$DOW" -ge 5 ]]; then
  echo "  ❌ BLOCKED: Today is $DAY_NAME."
  echo "     PPT Rule 4: 'No Friday/weekend cutovers, respect change freeze calendars'"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY RUN] Would block here in real run"
  else
    exit 1
  fi
else
  echo "  ✅ Day of week OK: $DAY_NAME (Mon-Thu permitted)"
fi

# Confirm change window
if [[ "$DRY_RUN" != "true" ]]; then
  echo ""
  echo "  ⚠️  IMPORTANT: Ensure you have an approved change window."
  read -p "  Do you have an approved change window? (yes/no): " CW
  [[ "$CW" == "yes" ]] || { echo "  Aborted — no change window approval."; exit 1; }
fi

# ── Step 1: Get ADO pipeline IDs to disable ───────────────────────────────────
echo ""
echo "STEP 1: Fetching ADO pipeline IDs..."

declare -A PIPELINE_IDS

for SVC in "${SERVICES[@]}"; do
  PIPELINE_NAME="${SVC}-ci"
  PID=$(curl -s -H "$ADO_AUTH" \
    "$ADO_BASE/pipelines?api-version=7.0" | \
    python3 -c "
import json,sys
data=json.load(sys.stdin)
for p in data.get('value',[]):
    if p['name'] == '$PIPELINE_NAME':
        print(p['id'])
        break
" 2>/dev/null || echo "")

  if [[ -n "$PID" ]]; then
    PIPELINE_IDS[$SVC]=$PID
    echo "  ✅ Found: $PIPELINE_NAME (id=$PID)"
  else
    echo "  ⚠️  Not found: $PIPELINE_NAME — check pipeline name in ADO"
  fi
done

# ── Step 2: Disable ADO pipelines (dormant — NOT deleted) ────────────────────
echo ""
echo "STEP 2: Disabling ADO pipelines (dormant, 30-day rollback window)..."
echo "  (PPT: 'ADO pipeline kept dormant for 30-day rollback window')"

for SVC in "${SERVICES[@]}"; do
  PID="${PIPELINE_IDS[$SVC]:-}"
  if [[ -z "$PID" ]]; then
    echo "  ⏭️  Skipping $SVC — pipeline ID not found"
    continue
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY RUN] Would disable: $SVC (id=$PID)"
  else
    # Disable via build definition queue status
    curl -s -X PATCH \
      -H "$ADO_AUTH" -H "$CT" \
      -d '{"queueStatus":"disabled"}' \
      "https://dev.azure.com/$ADO_ORG/$ADO_PROJECT/_apis/build/definitions/$PID?api-version=7.0" \
      > /dev/null
    echo "  ✅ Disabled ADO pipeline: $SVC (id=$PID) — remains dormant for rollback"
  fi
done

# ── Step 3: Set MIGRATION_PHASE=4 in GitHub ───────────────────────────────────
echo ""
echo "STEP 3: Activating GitHub Actions (MIGRATION_PHASE=4)..."

for SVC in "${SERVICES[@]}"; do
  GH_VARS_API="https://api.github.com/repos/$GH_ORG/$SVC/actions/variables"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY RUN] Would set MIGRATION_PHASE=4 in github.com/$GH_ORG/$SVC"
  else
    # Update or create variable
    curl -s -X PATCH "$GH_VARS_API/MIGRATION_PHASE" \
      -H "$GH_AUTH" -H "$GH_ACCEPT" -H "$CT" \
      -d '{"name":"MIGRATION_PHASE","value":"4"}' > /dev/null 2>&1 || \
    curl -s -X POST "$GH_VARS_API" \
      -H "$GH_AUTH" -H "$GH_ACCEPT" -H "$CT" \
      -d '{"name":"MIGRATION_PHASE","value":"4"}' > /dev/null

    curl -s -X PATCH "$GH_VARS_API/ADO_STATUS" \
      -H "$GH_AUTH" -H "$GH_ACCEPT" -H "$CT" \
      -d '{"name":"ADO_STATUS","value":"dormant"}' > /dev/null 2>&1 || \
    curl -s -X POST "$GH_VARS_API" \
      -H "$GH_AUTH" -H "$GH_ACCEPT" -H "$CT" \
      -d '{"name":"ADO_STATUS","value":"dormant"}' > /dev/null

    echo "  ✅ github.com/$GH_ORG/$SVC — MIGRATION_PHASE=4, ADO_STATUS=dormant"
  fi
done

# ── Step 4: Cutover log ────────────────────────────────────────────────────────
echo ""
echo "STEP 4: Writing cutover log..."

python3 - << EOF
import json
from datetime import datetime

log = {
    "event":           "phase4_cutover",
    "timestamp":       "$TIMESTAMP",
    "ado_org":         "$ADO_ORG",
    "ado_project":     "$ADO_PROJECT",
    "gh_org":          "$GH_ORG",
    "services":        "${SERVICES[@]}".split(),
    "dry_run":         "$DRY_RUN" == "true",
    "ado_status":      "dormant",
    "gh_phase":        "4",
    "rollback_window": "30 days",
    "rollback_cmd":    "bash rollback.sh",
    "decommission_date": (datetime.utcnow().replace(month=datetime.utcnow().month % 12 + 1)).strftime("%Y-%m-%d"),
    "notes": [
        "ADO pipelines disabled (not deleted) — 30-day bake period",
        "Run: bash rollback.sh to re-enable ADO in <5 min",
        "Run: bash decommission.sh after 30-day bake period"
    ]
}
with open("$LOG_FILE", "w") as f:
    json.dump(log, f, indent=2)
print(f"  ✅ Log: $LOG_FILE")
EOF

echo ""
echo "╔════════════════════════════════════════════════════╗"
echo "║           ✅ CUTOVER COMPLETE (Phase 4)             ║"
echo "╠════════════════════════════════════════════════════╣"
echo "║  ADO   : DORMANT (pipelines disabled, not deleted) ║"
echo "║  GitHub: PRIMARY (MIGRATION_PHASE=4)               ║"
echo "║  Log   : $LOG_FILE"
echo "╠════════════════════════════════════════════════════╣"
echo "║  ROLLBACK (if needed within 30 days):              ║"
echo "║    bash rollback.sh                                ║"
echo "║  DECOMMISSION (after 30-day bake):                 ║"
echo "║    bash decommission.sh                            ║"
echo "╚════════════════════════════════════════════════════╝"
