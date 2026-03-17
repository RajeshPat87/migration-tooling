# ADO → GitHub Actions Migration POC
## Based on: ADO_to_GHA_Migration_Plan_v2.pptx — Zero-Downtime Parallel-Run Strategy

---

## Repository Overview

```
migration-poc/
├── bmi-service/                    ← EXISTING ADO repo (Repo 1)
│   ├── src/app.py                  ← BMI calculator REST API
│   ├── src/requirements.txt
│   ├── Dockerfile
│   ├── tests/test_bmi.py
│   ├── .azure-pipelines/ci.yml     ← EXISTING ADO pipeline (source of truth)
│   └── .github/workflows/
│       └── shadow-ci.yml           ← GHA workflow (shadow in Phase 2/3, primary in Phase 4)
│
├── unit-converter/                 ← EXISTING ADO repo (Repo 2)
│   ├── src/app.py                  ← KM → miles/NM/feet/cm + temp/weight converter
│   ├── src/requirements.txt
│   ├── Dockerfile
│   ├── tests/test_converter.py
│   ├── .azure-pipelines/ci.yml     ← EXISTING ADO pipeline (source of truth)
│   └── .github/workflows/
│       └── shadow-ci.yml           ← GHA workflow (shadow → primary)
│
├── central-gh-templates/           ← NEW — Org-level reusable workflows (PPT Slide 5)
│   └── .github/workflows/
│       ├── reusable-build.yml      ← Reusable Docker build (phase-aware)
│       └── reusable-deploy.yml     ← Reusable Helm deploy (Phase 3+ only)
│
└── migration-tooling/              ← Migration orchestration engine
    ├── mirror/
    │   └── mirror-sync.sh          ← Phase 1: ADO→GH git mirror sync
    ├── importer/
    │   ├── run-importer.sh         ← gh-actions-importer: audit/dryrun/migrate
    │   └── inject-phase-gates.py   ← Post-processor: adds phase gates to converted YAML
    ├── validator/
    │   └── parity-checker.py       ← Phase 3: Compare ADO vs GHA (≥98% parity gate)
    ├── cutover/
    │   ├── cutover.sh              ← Phase 4: Disable ADO, activate GHA
    │   └── rollback.sh             ← Emergency: re-enable ADO in <5 min
    └── scripts/
        └── bootstrap.sh            ← One-time setup: create GH repos, secrets, mirror
```

---

## Migration Phases

```
Phase 1 — MIRROR
  ADO: Source of truth. Developers push to ADO. CI/CD runs in ADO.
  GH:  Receives git mirror every push + cron every 5 min.
  Action: Run bootstrap.sh + add MirrorToGitHub stage to ADO pipelines.

Phase 2 — SHADOW
  ADO: Deploys to production.
  GH:  Builds & tests but does NOT deploy. Shadow artifacts captured.
  Action: Set MIGRATION_PHASE=2 in GH repo variables.

Phase 3 — VALIDATE (2-week parallel run)
  ADO: Deploys to production.
  GH:  Shadow-deploys to staging. Parity score calculated.
  Gate: ≥98% parity required before Phase 4 (parity-checker.py).
  Action: Set MIGRATION_PHASE=3. Run parity-checker.py after each build.

Phase 4 — CUTOVER
  ADO: DORMANT (disabled, not deleted — 30-day rollback window).
  GH:  PRIMARY CI/CD. Deploys to production.
  Action: Run cutover.sh (Mon-Thu only, approved change window).

Phase 5 — DECOMMISSION
  ADO: Archive pipeline YAML. Remove agent pools.
  GH:  Sole CI/CD.
  Action: After 30-day bake period with zero incidents.
```

---

## Quick Start

### Prerequisites
```bash
# Tools required
az --version          # Azure CLI
gh --version          # GitHub CLI
docker --version      # Docker
helm version          # Helm 3.x
python3 --version     # Python 3.x

# Required env vars
export ADO_PAT=""
export ADO_ORG=""
export ADO_PROJECT=""
export GH_PAT=""
export GH_ORG=""
export AZURE_CREDENTIALS=''
export ACR_NAME=""
export ACR_LOGIN_SERVER=""
export AKS_CLUSTER=""
export AKS_RG=""
```

### Step 1 — One-time bootstrap (creates GH repos, sets secrets, does initial mirror)
```bash
bash migration-tooling/scripts/bootstrap.sh
```

### Step 2 — Import existing ADO pipelines into GHA (importer)
```bash
cd migration-tooling/importer

export ADO_ACCESS_TOKEN="$ADO_PAT"
export ADO_ORGANIZATION="$ADO_ORG"
export ADO_PROJECT="$ADO_PROJECT"
export GH_ACCESS_TOKEN="$GH_PAT"
export GH_ORGANIZATION="$GH_ORG"

bash run-importer.sh audit     # Scan ADO pipelines, readiness report
bash run-importer.sh dryrun    # Preview converted YAML
bash run-importer.sh migrate   # Convert + create PRs in GH repos

# Post-process: inject migration phase gates into imported workflows
python3 inject-phase-gates.py --input-dir ./importer-output-*/migrate
```

### Step 3 — Push app repos to ADO (if not already there)
```bash
# bmi-service
cd bmi-service
git init && git add . && git commit -m "Initial commit"
git remote add origin https://dev.azure.com/$ADO_ORG/$ADO_PROJECT/_git/bmi-service
git push origin main

# unit-converter
cd ../unit-converter
git init && git add . && git commit -m "Initial commit"
git remote add origin https://dev.azure.com/$ADO_ORG/$ADO_PROJECT/_git/unit-converter
git push origin main
```

### Step 4 — Create ADO pipelines in ADO UI
```
Azure DevOps → Pipelines → New Pipeline → Azure Repos Git
  bmi-service     → select: .azure-pipelines/ci.yml   → name: bmi-service-ci
  unit-converter  → select: .azure-pipelines/ci.yml   → name: unit-converter-ci
```

### Step 5 — Create ADO Variable Group
```
Azure DevOps → Library → Variable Groups → New group: aks-migration-vg
Add variables:
  AZURE_SERVICE_CONNECTION = <your-azure-service-connection>
  ACR_SERVICE_CONNECTION   = <your-acr-service-connection>
  ACR_LOGIN_SERVER         = <acr>.azurecr.io
  AKS_CLUSTER_NAME         = <aks-cluster>
  AKS_RESOURCE_GROUP       = <resource-group>
  GITHUB_ORG               = <gh-org>
  GITHUB_REPO              = bmi-service  (per pipeline)
  GITHUB_PAT               = <gh-pat>     (mark as secret)
```

### Step 6 — Enter Phase 2 (Shadow)
```bash
# Set in BOTH repo variables in GitHub
# GitHub → repo → Settings → Secrets and variables → Actions → Variables
# Name: MIGRATION_PHASE   Value: 2
# (Or use the API)
for SVC in bmi-service unit-converter; do
  curl -s -X POST "https://api.github.com/repos/$GH_ORG/$SVC/actions/variables" \
    -H "Authorization: Bearer $GH_PAT" \
    -H "Accept: application/vnd.github.v3+json" \
    -d '{"name":"MIGRATION_PHASE","value":"2"}'
done
```

### Step 7 — Validate (Phase 3, 2-week parallel run)
```bash
# Download ADO and GHA test artifacts, then:
python3 migration-tooling/validator/parity-checker.py \
  --ado-artifacts ./ado-artifacts \
  --gha-artifacts ./gha-artifacts \
  --output-report parity-report.json

# Must show ≥98% parity to proceed to cutover
```

### Step 8 — Cutover (Phase 4, Mon-Thu, approved change window)
```bash
export ADO_PAT GH_PAT ADO_ORG ADO_PROJECT GH_ORG
bash migration-tooling/cutover/cutover.sh        # interactive
bash migration-tooling/cutover/cutover.sh --dry-run  # preview first
```

### Rollback (if needed, within 30 days)
```bash
bash migration-tooling/cutover/rollback.sh   # re-enables ADO in <5 min
```

---

## Application Endpoints

### BMI Service (port 8080)
```
POST /bmi             {"weight_kg": 70, "height_cm": 175}
GET  /bmi/category    list all BMI categories
GET  /health
GET  /
```

### Unit Converter (port 8081)
```
POST /convert         {"value": 100, "type": "km_to_miles"}
GET  /convert/types   all supported conversions
GET  /health
GET  /

Supported types: km_to_miles, km_to_nm, km_to_feet, km_to_m, km_to_cm,
                 miles_to_km, kg_to_lbs, lbs_to_kg, c_to_f, f_to_c, c_to_k, ...
```

---

## PPT Mapping

| PPT Element | Implementation |
|-------------|----------------|
| Source of Truth (ADO) | `.azure-pipelines/ci.yml` — live, primary CI/CD |
| Mirror Sync | `MirrorToGitHub` stage in ADO CI + `mirror-sync.sh` |
| GH Actions Importer | `importer/run-importer.sh` (audit/dryrun/migrate) |
| Shadow Runner | GHA `shadow-ci.yml` triggered by `repository_dispatch` |
| Validation Gate (≥98%) | `validator/parity-checker.py` |
| Cutover Controller | `cutover/cutover.sh` |
| Rollback Handler (<5min) | `cutover/rollback.sh` |
| Reusable Workflow Library | `central-gh-templates/.github/workflows/` |
| OIDC Federation | GHA uses `AZURE_CREDENTIALS` (no PATs for Azure) |
| Production Safety Rules | Cutover.sh: day-of-week check, change window confirmation |
