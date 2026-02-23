#!/bin/bash
# =============================================================================
# migration-tooling/importer/run-importer.sh
# PPT Slide 3+5: "GH Actions Importer — Pipeline YAML conversion"
# Converts the EXISTING ADO pipelines → GitHub Actions workflows
#
# Workflow:
#   Step 1: audit      — scan all ADO pipelines, produce readiness report
#   Step 2: dry-run    — preview converted YAML (no commit to GH)
#   Step 3: migrate    — convert + create PRs in GH repos
#   Step 4: post-proc  — inject migration phase gates into imported workflows
#
# Prerequisites:
#   gh CLI installed, docker running
#   export ADO_ACCESS_TOKEN="<ado-pat>"
#   export ADO_ORGANIZATION="<org>"
#   export ADO_PROJECT="<project>"
#   export GH_ACCESS_TOKEN="<gh-pat>"
#   export GH_ORGANIZATION="<org>"
# =============================================================================

set -euo pipefail

COMMAND="${1:-help}"   # audit | dryrun | migrate | all

ADO_ACCESS_TOKEN="${ADO_ACCESS_TOKEN:-}"
ADO_ORGANIZATION="${ADO_ORGANIZATION:-}"
ADO_PROJECT="${ADO_PROJECT:-}"
GH_ACCESS_TOKEN="${GH_ACCESS_TOKEN:-}"
GH_ORGANIZATION="${GH_ORGANIZATION:-}"

SERVICES=("bmi-service" "unit-converter")
OUTPUT_BASE="./importer-output-$(date +%Y%m%d-%H%M%S)"

# ── Validate ──────────────────────────────────────────────────────────────────
validate_env() {
  local MISSING=0
  for V in ADO_ACCESS_TOKEN ADO_ORGANIZATION ADO_PROJECT GH_ACCESS_TOKEN GH_ORGANIZATION; do
    if [[ -z "${!V:-}" ]]; then
      echo "❌ Required: $V"
      MISSING=1
    fi
  done
  [[ $MISSING -eq 0 ]] || exit 1
}

# ── Install importer ──────────────────────────────────────────────────────────
install_importer() {
  echo "Installing gh-actions-importer..."
  if gh extension list 2>/dev/null | grep -q "github/gh-actions-importer"; then
    echo "  Already installed — upgrading..."
    gh extension upgrade gh-actions-importer
  else
    gh extension install github/gh-actions-importer
  fi
  gh actions-importer version
  echo "✅ gh-actions-importer ready"
}

# ── Audit all ADO pipelines ───────────────────────────────────────────────────
run_audit() {
  echo ""
  echo "================================================"
  echo "  STEP 1: Audit ADO Pipelines"
  echo "  Org    : $ADO_ORGANIZATION / $ADO_PROJECT"
  echo "================================================"
  mkdir -p "$OUTPUT_BASE/audit"

  gh actions-importer audit azure-devops \
    --output-dir "$OUTPUT_BASE/audit" \
    --azure-devops-access-token "$ADO_ACCESS_TOKEN" \
    --azure-devops-organization "$ADO_ORGANIZATION" \
    --azure-devops-project "$ADO_PROJECT" \
    --github-access-token "$GH_ACCESS_TOKEN" \
    --github-organization "$GH_ORGANIZATION"

  echo ""
  echo "✅ Audit complete → $OUTPUT_BASE/audit"
  [[ -f "$OUTPUT_BASE/audit/audit_summary.md" ]] && \
    cat "$OUTPUT_BASE/audit/audit_summary.md" || true
}

# ── Dry run per pipeline ───────────────────────────────────────────────────────
run_dryrun() {
  echo ""
  echo "================================================"
  echo "  STEP 2: Dry Run Conversions"
  echo "================================================"

  # ADO pipeline names to convert — match names in ADO UI
  declare -A ADO_PIPELINES=(
    ["bmi-service-ci"]="bmi-service"
    ["unit-converter-ci"]="unit-converter"
  )

  for PIPELINE_NAME in "${!ADO_PIPELINES[@]}"; do
    REPO="${ADO_PIPELINES[$PIPELINE_NAME]}"
    echo ""
    echo "--- Dry run: $PIPELINE_NAME ---"
    mkdir -p "$OUTPUT_BASE/dryrun/$REPO"

    gh actions-importer dry-run azure-devops pipeline \
      --output-dir "$OUTPUT_BASE/dryrun/$REPO" \
      --azure-devops-access-token "$ADO_ACCESS_TOKEN" \
      --azure-devops-organization "$ADO_ORGANIZATION" \
      --azure-devops-project "$ADO_PROJECT" \
      --pipeline-name "$PIPELINE_NAME" \
      --github-access-token "$GH_ACCESS_TOKEN" && \
      echo "  ✅ Dry run OK: $PIPELINE_NAME" || \
      echo "  ⚠️  Dry run issue: $PIPELINE_NAME — check manually"
  done

  echo ""
  echo "✅ Dry run complete → $OUTPUT_BASE/dryrun"
  echo "Review converted YAML before running migrate"
}

# ── Full migration ─────────────────────────────────────────────────────────────
run_migrate() {
  echo ""
  echo "================================================"
  echo "  STEP 3: Full Migration (creates GH PRs)"
  echo "================================================"
  echo "⚠️  This creates pull requests in GitHub repos"
  read -p "Continue? (yes/no): " CONFIRM
  [[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }

  declare -A ADO_PIPELINES=(
    ["bmi-service-ci"]="bmi-service"
    ["unit-converter-ci"]="unit-converter"
  )

  for PIPELINE_NAME in "${!ADO_PIPELINES[@]}"; do
    REPO="${ADO_PIPELINES[$PIPELINE_NAME]}"
    echo ""
    echo "--- Migrating: $PIPELINE_NAME → github.com/$GH_ORGANIZATION/$REPO ---"
    mkdir -p "$OUTPUT_BASE/migrate/$REPO"

    gh actions-importer migrate azure-devops pipeline \
      --output-dir "$OUTPUT_BASE/migrate/$REPO" \
      --azure-devops-access-token "$ADO_ACCESS_TOKEN" \
      --azure-devops-organization "$ADO_ORGANIZATION" \
      --azure-devops-project "$ADO_PROJECT" \
      --pipeline-name "$PIPELINE_NAME" \
      --github-access-token "$GH_ACCESS_TOKEN" \
      --github-organization "$GH_ORGANIZATION" \
      --github-repository "$REPO" \
      --target-url "https://github.com/$GH_ORGANIZATION/$REPO" && \
      echo "  ✅ Migrated: $PIPELINE_NAME (PR created in github.com/$GH_ORGANIZATION/$REPO)" || \
      echo "  ❌ Failed: $PIPELINE_NAME"
  done

  echo ""
  echo "✅ Migration complete → $OUTPUT_BASE/migrate"
  echo "Next: Review PRs in https://github.com/$GH_ORGANIZATION"
  echo "Then: Run post-process to inject migration phase gates"
  echo "      python3 ../post-process/inject-phase-gates.py --input-dir $OUTPUT_BASE/migrate"
}

# ── Help ───────────────────────────────────────────────────────────────────────
show_help() {
  cat << 'EOF'
Usage: ./run-importer.sh <command>

Commands:
  install   Install/upgrade gh-actions-importer
  audit     Scan all ADO pipelines — produces readiness report
  dryrun    Preview converted workflows (no GitHub changes)
  migrate   Full conversion + create PRs in GH repos
  all       Run: install → audit → dryrun → migrate

Required env vars:
  ADO_ACCESS_TOKEN    ADO PAT (Read pipeline scope)
  ADO_ORGANIZATION    ADO org name
  ADO_PROJECT         ADO project name
  GH_ACCESS_TOKEN     GitHub PAT (repo + workflow scope)
  GH_ORGANIZATION     GitHub org name

Examples:
  ./run-importer.sh audit
  ./run-importer.sh dryrun
  ./run-importer.sh migrate
EOF
}

# ── Entry ──────────────────────────────────────────────────────────────────────
case "$COMMAND" in
  install)  install_importer ;;
  audit)    validate_env; install_importer; run_audit ;;
  dryrun)   validate_env; install_importer; run_dryrun ;;
  migrate)  validate_env; install_importer; run_dryrun; run_migrate ;;
  all)      validate_env; install_importer; run_audit; run_dryrun; run_migrate ;;
  *)        show_help ;;
esac
