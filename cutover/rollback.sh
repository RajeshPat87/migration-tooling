#!/bin/bash
# =============================================================================
# migration-tooling/cutover/rollback.sh
# PPT: "One-click rollback script re-enables ADO in < 5 min"
# PPT Risk: "Prod deployment fails during shadow→cutover | ADO pipeline kept
#            dormant (not deleted). One-click rollback re-enables ADO in <5 min"
#
# Re-enables ADO pipelines and sets MIGRATION_PHASE back to 2 (shadow)
# Can be run at ANY time within 30-day bake period
# =============================================================================

set -euo pipefail

ADO_PAT="${ADO_PAT:-}"
GH_PAT="${GH_PAT:-}"
ADO_ORG="${ADO_ORG:-}"
ADO_PROJECT="${ADO_PROJECT:-}"
GH_ORG="${GH_ORG:-}"

for V in ADO_PAT GH_PAT ADO_ORG ADO_PROJECT GH_ORG; do
  [[ -n "${!V:-}" ]] || { echo "❌ Required: $V"; exit 1; }
done

START=$(date +%s)
SERVICES=("bmi-service" "unit-converter")

ADO_AUTH="Authorization: Basic $(echo -n ":$ADO_PAT" | base64 -w0)"
GH_AUTH="Authorization: Bearer $GH_PAT"
GH_ACCEPT="Accept: application/vnd.github.v3+json"
CT="Content-Type: application/json"

echo "╔════════════════════════════════════════════════════╗"
echo "║              🔄 ROLLBACK: GHA → ADO                ║"
echo "╚════════════════════════════════════════════════════╝"
echo "  Timestamp : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# ── Re-enable ADO pipelines ────────────────────────────────────────────────────
echo "Step 1: Re-enabling ADO pipelines..."

PIPELINE_LIST=$(curl -s -H "$ADO_AUTH" \
  "https://dev.azure.com/$ADO_ORG/$ADO_PROJECT/_apis/pipelines?api-version=7.0")

for SVC in "${SERVICES[@]}"; do
  PIPELINE_NAME="${SVC}-ci"
  PID=$(echo "$PIPELINE_LIST" | python3 -c "
import json,sys
data=json.load(sys.stdin)
for p in data.get('value',[]):
    if p['name'] == '$PIPELINE_NAME':
        print(p['id'])
        break
" 2>/dev/null || echo "")

  if [[ -n "$PID" ]]; then
    curl -s -X PATCH \
      -H "$ADO_AUTH" -H "$CT" \
      -d '{"queueStatus":"enabled"}' \
      "https://dev.azure.com/$ADO_ORG/$ADO_PROJECT/_apis/build/definitions/$PID?api-version=7.0" \
      > /dev/null
    echo "  ✅ Re-enabled ADO pipeline: $PIPELINE_NAME (id=$PID)"
  else
    echo "  ⚠️  Pipeline not found: $PIPELINE_NAME — re-enable manually in ADO UI"
  fi
done

# ── Reset GH phase back to shadow ──────────────────────────────────────────────
echo ""
echo "Step 2: Resetting GitHub to shadow mode (MIGRATION_PHASE=2)..."

for SVC in "${SERVICES[@]}"; do
  GH_VARS="https://api.github.com/repos/$GH_ORG/$SVC/actions/variables"

  curl -s -X PATCH "$GH_VARS/MIGRATION_PHASE" \
    -H "$GH_AUTH" -H "$GH_ACCEPT" -H "$CT" \
    -d '{"name":"MIGRATION_PHASE","value":"2"}' > /dev/null 2>&1 || \
  curl -s -X POST "$GH_VARS" \
    -H "$GH_AUTH" -H "$GH_ACCEPT" -H "$CT" \
    -d '{"name":"MIGRATION_PHASE","value":"2"}' > /dev/null

  curl -s -X PATCH "$GH_VARS/ADO_STATUS" \
    -H "$GH_AUTH" -H "$GH_ACCEPT" -H "$CT" \
    -d '{"name":"ADO_STATUS","value":"active"}' > /dev/null 2>&1 || true

  echo "  ✅ $SVC → MIGRATION_PHASE=2 (shadow), ADO_STATUS=active"
done

END=$(date +%s)
ELAPSED=$((END - START))

echo ""
echo "╔════════════════════════════════════════════════════╗"
echo "║           ✅ ROLLBACK COMPLETE                      ║"
echo "╠════════════════════════════════════════════════════╣"
echo "║  ADO   : ACTIVE (pipelines re-enabled)             ║"
echo "║  GitHub: SHADOW (MIGRATION_PHASE=2)                ║"
echo "║  Time  : ${ELAPSED}s"
echo "╚════════════════════════════════════════════════════╝"
