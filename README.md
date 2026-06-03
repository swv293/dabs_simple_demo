# DABs Simple Demo

A complete, runnable **Databricks Asset Bundles (DABs)** teaching demo. One bundle file describes a UC schema + volume, a 4-task daily ETL job, and a Lakeview dashboard — then deploys them to `dev`, `staging`, or `prod` with environment-specific configuration. A single command deploys everything. A single command tears it all down.

Works on **any Databricks workspace** with Unity Catalog and a Serverless SQL Warehouse. If you don't have one, sign up for [Databricks Free Edition](https://www.databricks.com/learn/free-edition) — no credit card, single-user workspace with serverless pre-provisioned.

---

## 1. What is a DAB?

A Databricks Asset Bundle is **declarative infrastructure-as-code for a Databricks workspace.** You describe your jobs, pipelines, schemas, dashboards, and permissions in YAML. The CLI renders those descriptions into workspace resources at deploy time.

Key idea: the same bundle YAML deploys to `dev` with a prefixed, isolated name _and_ to `prod` with a service principal, different catalog, and open schedule — no copy-paste, no drift.

---

## 2. Repo tour

```
dabs_simple_demo/
├── databricks.yml            ← bundle root: identity, variables, targets (environments)
├── resources/
│   ├── schema.yml            ← UC schema + managed volume
│   ├── job.yml               ← daily_etl workflow (4 tasks)
│   └── dashboard.yml         ← Lakeview dashboard
├── src/
│   ├── notebooks/ingest.py   ← generates synthetic orders, COPY INTO bronze
│   ├── sql/
│   │   ├── 01_ddl.sql        ← idempotent table DDL (parameterized)
│   │   ├── 02_silver.sql     ← bronze → silver (typed, deduped)
│   │   └── 03_gold.sql       ← silver → gold_daily_revenue aggregate
│   └── dashboard/demo.lvdash.json   ← exported dashboard definition
├── scripts/
│   ├── demo_deploy.sh        ← validate + deploy + run in one command
│   └── teardown.sh           ← wipe the deployment for a clean re-run
├── tests/
│   ├── bundle_validate.sh    ← validates all targets (no deploy)
│   └── unit/test_ingest_helpers.py  ← pytest for the Python helper
└── azure-pipelines.yml       ← CI/CD talk-track (not run live; see §8)
```

---

## 3. Prerequisites

| Requirement | Notes |
|---|---|
| Databricks CLI ≥ 0.240 | `brew install databricks` or `curl -fsSL … \| sh` |
| Terraform ≥ 1.5 | `brew install hashicorp/tap/terraform` |
| Databricks workspace | Any workspace with Unity Catalog + Serverless SQL Warehouse ([Free Edition](https://www.databricks.com/learn/free-edition) works) |
| `databricks auth login` | Configure a profile for your workspace |

> **Free Edition / single-catalog workspaces:** catalog creation via the CLI may require an explicit storage location. Use the `workspace` catalog (pre-created on Free Edition) and differentiate environments by schema name — set `catalog: workspace` in each target's variables. The isolation story is identical, just at the schema level (see §6).

After installing the CLI, authenticate:

```bash
databricks auth login --host https://<your-workspace>.cloud.databricks.com
```

Set these env vars once — add them to your shell profile or a gitignored `.env` file. Nothing workspace-specific lives in the YAML:

```bash
# Required — your workspace URL
export DATABRICKS_HOST="https://<your-workspace>.cloud.databricks.com"

# Required — the UC catalog to deploy into (Free Edition default is "workspace")
export BUNDLE_VAR_catalog="workspace"

# Required — system Terraform (avoids CLI PGP key expiry issues)
export DATABRICKS_TF_EXEC_PATH="$(which terraform)"
export DATABRICKS_TF_VERSION="1.15.5"
```

`BUNDLE_VAR_catalog` is the `BUNDLE_VAR_` prefix convention — any bundle variable `x` can be set via `BUNDLE_VAR_x` without touching the YAML. You can also pass it inline: `--var catalog=workspace`.

---

## 4. `databricks.yml` walkthrough

Open `databricks.yml`. The file has four sections:

**Bundle identity**
```yaml
bundle:
  name: dabs_simple_demo
```

**Include** — pulls in the resource files so the root stays readable:
```yaml
include:
  - resources/*.yml
```

**Variables** — declared once, overridden per target. The `lookup:` form resolves a warehouse name to its ID at deploy time so you never hardcode IDs:
```yaml
variables:
  catalog:
    description: UC catalog this target writes into
  warehouse_id:
    lookup:
      warehouse: Serverless Starter Warehouse   # resolved at deploy time
  notifications_email:
    default: ${workspace.current_user.userName} # falls back to current user
```

**Targets** — one block per environment. `workspace.host` is intentionally absent from every target — the bundle resolves it from `DATABRICKS_HOST` (env var), `DATABRICKS_CONFIG_PROFILE`, or the `--profile` CLI flag. This keeps all workspace-specific values out of source control:

```yaml
targets:
  dev:
    mode: development           # auto-prefix names, auto-pause schedules
    default: true
    variables:
      schema_name: dabs_demo_dev
    run_as:
      user_name: ${workspace.current_user.userName}

  staging:
    mode: development
    variables:
      schema_name: dabs_demo_staging
    presets:
      name_prefix: "[staging-${workspace.current_user.short_name}] "

  prod:
    mode: production            # unpauses schedule, removes name prefix
    workspace:
      root_path: /Workspace/Shared/.bundle/${bundle.name}/${bundle.target}
    variables:
      schema_name: dabs_demo_prod
    run_as:
      service_principal_name: ${var.prod_sp}   # SP, not a human
    permissions:
      - level: CAN_MANAGE
        group_name: data-platform-admins
```

`catalog` has no hardcoded value in any target — it inherits the variable default (`workspace`) and is overridden per-environment via `BUNDLE_VAR_catalog` or `--var catalog=<name>`.

**The three things targets do:**
1. Override `variables` — what schema/config to use (`catalog` comes from the environment)
2. Override behaviour via `mode:` + `run_as:` + `permissions:`
3. Override `workspace.root_path` for prod — moves bundle state to a shared folder

**How workspace host resolution works:**

| Priority | Mechanism |
|---|---|
| 1 (highest) | `DATABRICKS_HOST` environment variable |
| 2 | `DATABRICKS_CONFIG_PROFILE` env var → `~/.databrickscfg` profile |
| 3 | `--profile` / `-p` CLI flag → `~/.databrickscfg` profile |
| 4 | Default profile in `~/.databrickscfg` |

---

## 5. Resources walkthrough

### `resources/schema.yml` — UC schema + volume

```yaml
resources:
  schemas:
    demo:
      catalog_name: ${var.catalog}
      name: ${var.schema_name}
  volumes:
    demo_raw:
      catalog_name: ${var.catalog}
      schema_name: ${resources.schemas.demo.name}   # cross-resource reference
      name: raw
      volume_type: MANAGED
```

`${resources.schemas.demo.name}` resolves to the **actual deployed schema name**, including any `mode: development` prefix. This is how you chain resources without hardcoding names.

---

### `resources/job.yml` — 4-task daily ETL

```yaml
environments:
  - environment_key: serverless_env
    spec:
      client: "1"        # serverless notebook compute

tasks:
  - task_key: ddl
    sql_task:
      warehouse_id: ${var.warehouse_id}
      file: { path: ../src/sql/01_ddl.sql }
      parameters:
        catalog: ${var.catalog}
        schema:  ${resources.schemas.demo.name}   # ← resolved name, not the variable

  - task_key: ingest
    depends_on: [{ task_key: ddl }]
    environment_key: serverless_env
    notebook_task:
      notebook_path: ../src/notebooks/ingest.py
      base_parameters:
        catalog: ${var.catalog}
        schema:  ${resources.schemas.demo.name}
        volume:  ${resources.volumes.demo_raw.name}

  - task_key: silver
    depends_on: [{ task_key: ingest }]
    sql_task: { … file: 02_silver.sql … }

  - task_key: gold
    depends_on: [{ task_key: silver }]
    sql_task: { … file: 03_gold.sql … }

schedule:
  quartz_cron_expression: "0 0 6 * * ?"
  pause_status: PAUSED   # mode:development auto-pauses; prod unpauses
```

> **Why `${resources.schemas.demo.name}` and not `${var.schema_name}`?**
> In `mode: development` the bundle prefixes the schema name with `[target]-[user]-`. If you pass the bare variable value as a SQL parameter the task writes to a different (unmanaged) schema. Always use the resource reference when passing the schema to tasks.

---

### `resources/dashboard.yml` — Lakeview dashboard

```yaml
resources:
  dashboards:
    demo_dashboard:
      display_name: "[${bundle.target}] DABs Demo Dashboard"
      warehouse_id: ${var.warehouse_id}
      parent_path: /Workspace/Users/${workspace.current_user.userName}
      file_path: ../src/dashboard/demo.lvdash.json
```

The `.lvdash.json` is a dashboard export. By default, dataset queries inside it contain fully-qualified table names (`catalog.schema.table`) hardcoded to the environment they were exported from. There are three ways to handle multi-environment promotion:

**Option 1 — `dataset_catalog` + `dataset_schema` (recommended):**
Add these two fields to `dashboard.yml` and write your `.lvdash.json` SQL with *unqualified* table names only (just `table_name` or `schema.table_name`, no catalog prefix). DABs injects the catalog and schema at deploy time:

```yaml
resources:
  dashboards:
    demo_dashboard:
      display_name: "[${bundle.target}] DABs Demo Dashboard"
      warehouse_id: ${var.warehouse_id}
      parent_path: /Workspace/Users/${workspace.current_user.userName}
      file_path: ../src/dashboard/demo.lvdash.json
      dataset_catalog: ${var.catalog}               # ← injected per target
      dataset_schema:  ${resources.schemas.demo.name}  # ← injected per target
```

Inside the `.lvdash.json` SQL, reference only the table name:
```sql
SELECT order_date, region, orders, revenue
FROM gold_daily_revenue   -- no catalog.schema prefix
ORDER BY order_date
```
DABs applies `dataset_catalog`/`dataset_schema` as the default for any dataset query that doesn't specify them explicitly. See [Bundle examples — Dashboard parameterization](https://docs.databricks.com/aws/en/dev-tools/bundles/examples#dashboard-dataset) and [Dashboard resource reference](https://docs.databricks.com/aws/en/dev-tools/bundles/resources#dashboard).

---

**Option 2 — Re-export after first deploy per environment:**
Deploy to the target, open the deployed dashboard in the workspace UI, make any layout adjustments, then export the file:
```bash
# 1. Deploy the bundle (creates the dashboard in the target workspace)
databricks bundle deploy -t staging

# 2. Get the dashboard ID from bundle summary
databricks bundle summary -t staging -o json | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d['resources']['dashboards']['demo_dashboard']['id'])"

# 3. Export the dashboard file via the workspace API
DASHBOARD_ID=<id-from-step-2>
databricks api get /api/2.0/workspace/export \
  --path "/Workspace/Users/${USER}/dabs_demo/staging/[staging] DABs Demo Dashboard.lvdash.json" \
  --direct_download > src/dashboard/demo_staging.lvdash.json

# 4. Commit the updated file, point dashboard.yml file_path at it for the staging target
```

---

**Option 3 — `sed` rewrite in CI before deploy:**
If your SQL uses fully-qualified `catalog.schema.table` names, a pre-deploy substitution is the simplest mechanical fix. In `mode: development` the deployed schema name is prefixed with `[target]-[username]-`, so the pattern to replace looks like `dev_<username>_dabs_demo_dev`. In CI, use the known environment values:
```bash
# In azure-pipelines.yml, before `bundle deploy -t prod`:
sed -i "s/${DEV_SCHEMA}/${PROD_SCHEMA}/g" src/dashboard/demo.lvdash.json
```
This is fragile — any schema rename breaks it — but works for simple demos where the only difference is the schema name. Option 1 (`dataset_catalog` + `dataset_schema`) is strongly preferred.

---

## 6. Per-target overview

| Setting | `dev` | `staging` | `prod` |
|---|---|---|---|
| Workspace host | `DATABRICKS_HOST` env var | `DATABRICKS_HOST` env var | `DATABRICKS_HOST` env var (prod workspace) |
| Catalog | `BUNDLE_VAR_catalog` (default: `workspace`) | same | `BUNDLE_VAR_catalog` (prod catalog) |
| Schema (deployed name) | `[dev-<user>-]dabs_demo_dev` | `[staging-<short>-]dabs_demo_staging` | `dabs_demo_prod` |
| Schedule | Auto-paused (`mode: development`) | Paused (same mode) | 06:00 ET daily — unpaused |
| Runs as | Current user | Current user | Service principal |
| Permissions block | none | none | `CAN_MANAGE` for admins group |
| Root path | per-user `.bundle/` folder | per-user `.bundle/` folder | `/Workspace/Shared/.bundle/` |

> **Catalogs vs schemas for isolation:** The ideal pattern is one catalog per environment (`dev_orders`, `staging_orders`, `prod_orders`). On workspaces where catalog creation is restricted — including Free Edition, which gives you a single `workspace` catalog — use one catalog with per-target schema names. The isolation story is identical, just one level down.

---

## 7. The four CLI verbs

```bash
# 1. Check the YAML is valid — fast, no workspace changes
databricks bundle validate -t dev

# 2. Deploy all resources to the workspace
databricks bundle deploy -t dev

# 3. Run the job and wait for completion
databricks bundle run daily_etl -t dev

# 4. Wipe everything — idempotent
databricks bundle destroy -t dev
```

Or use the helper scripts:

```bash
./scripts/demo_deploy.sh dev    # validate + deploy + run in one shot
./scripts/teardown.sh dev       # destroy + belt-and-suspenders schema drop
```

---

## 8. CI/CD walkthrough — `azure-pipelines.yml` (talk-track)

> This file ships in the repo as a **readable artifact**. It illustrates the promotion model — it is not executed in the live demo.

The pipeline has four stages:

```
PR opened              → Validate (bundle validate × 3 targets + pytest)
Merge to main          → Deploy_Dev (automatic)
Push to release/*      → Deploy_Staging (optional light approval)
Push a v* tag          → Deploy_Prod  ← PAUSES for human approval
```

The human gate lives in the **Azure DevOps Environments UI** for `databricks-prod` — not in the YAML. A reviewer clicks Approve; the pipeline then runs `databricks bundle deploy -t prod` using service-principal credentials scoped to that environment.

**Auth per environment:**

| Environment | Where creds live |
|---|---|
| `databricks-dev`, `databricks-staging` | Pipeline secret variables: `DATABRICKS_HOST`, `DATABRICKS_CLIENT_ID`, `DATABRICKS_CLIENT_SECRET` |
| `databricks-prod` | Same variable names, different values, scoped to the `databricks-prod` ADO environment |

Same commands, different credentials, different workspace, different target. That is the whole promotion model.

---

## 9. Live demo runbook

Exact sequence for the live demo (single terminal, ~6 minutes):

```bash
cd ~/dabs_simple_demo

# Step 1 — validate (show the clean output)
databricks bundle validate -t dev

# Step 2 — deploy (narrate: job / schema / volume / dashboard being created)
databricks bundle deploy -t dev

# Step 3 — open workspace UI
#   → Jobs: "[dev <user>] daily_etl" with 4 tasks, schedule paused
#   → Catalog Explorer: schema dev_<user>_dabs_demo_dev, volume raw
#   → Dashboards: "[dev] DABs Demo Dashboard" (no data yet)

# Step 4 — run the pipeline (~90 seconds)
databricks bundle run daily_etl -t dev

# Step 5 — refresh dashboard → revenue trend, top products, orders by region

# Step 6 — teardown (audience sees workspace go clean)
./scripts/teardown.sh dev

# Step 7 — redeploy in one line (reinforces "this is one command")
./scripts/demo_deploy.sh dev
```

**Timing budget:** validate 5s · deploy 20s · run 90s · UI tour 2 min · teardown 20s · redeploy 2 min.

---

## 10. 🪄 Genie Code moments

These are the steps you can **generate live on stage** with Databricks Assistant. The pre-shipped files are the expected output — useful if generation goes sideways, or to skip ahead.

| 🪄 | Where | Prompt |
|---|---|---|
| `01_ddl.sql` | Workspace SQL editor | *"Create idempotent DDL for bronze_orders (raw strings), silver_orders (typed + deduped on order_id), and gold_daily_revenue (order_date, region, orders, revenue). Use :catalog and :schema SQL parameters."* |
| `ingest.py` | New notebook | *"Generate 5,000 synthetic order rows with order_id, customer_id, product_id (P001–P020), region (N/S/E/W), order_date (last 30 days), amount (5–500). Write CSV to /Volumes/{catalog}/{schema}/raw/orders.csv then COPY INTO bronze_orders. Read catalog, schema, volume from dbutils widgets."* |
| `02_silver.sql` | SQL editor | *"INSERT OVERWRITE silver_orders from bronze_orders: cast order_date to DATE, amount to DECIMAL(10,2), dedupe on order_id keeping the latest _ingested_at."* |
| `03_gold.sql` | SQL editor | *"Aggregate silver_orders to gold_daily_revenue: group by order_date and region, sum(amount) as revenue, count(*) as orders."* |
| Dashboard widgets | Lakeview editor → Add with AI | *"Line chart of revenue over time"* and *"Top 10 products by revenue"* |
| Add `staging` target | VS Code + Databricks extension | *"Add a target called staging that uses catalog workspace, schema_name dabs_demo_staging, and mode: development."* |

---

## 11. Adapting this demo

To swap in your own pipeline:

1. **Replace `src/sql/01_ddl.sql`** with your DDL — keep `:catalog`/`:schema` parameters.
2. **Replace `src/notebooks/ingest.py`** with your ingestion logic; keep `dbutils.widgets` for `catalog`/`schema`/`volume`.
3. **Update `resources/job.yml`** task list to match your steps; keep `${resources.schemas.demo.name}` for the schema parameter.
4. **Export your own `.lvdash.json`** from the workspace after the first successful run.
5. **Update `databricks.yml` targets** with your workspace hosts, catalogs, and service principal.

The variable and resource-reference patterns stay the same regardless of domain.

---

## 12. Cleanup

```bash
./scripts/teardown.sh dev
./scripts/teardown.sh staging
```

Or directly:

```bash
databricks bundle destroy -t dev --auto-approve
```

`bundle destroy` removes: the job, the dashboard, the UC schema (cascade: tables + volume). The workspace is left clean.
