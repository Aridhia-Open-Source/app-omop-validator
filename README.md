# OMOP CDM Validator for Aridhia DRE

A single-file R Shiny application that checks whether a PostgreSQL schema conforms to
the OMOP Common Data Model, finds column type mismatches against the spec, generates a
remediation SQL script, and (with explicit confirmation) applies it inside a transaction.
Built for deployment to an Aridhia Digital Research Environment (DRE) Project Workspace,
where it reads from and writes to the workspace PostgreSQL database directly.

The validator is deliberately narrow. It does one job, conformance and type remediation,
and leaves cohort building, analysis, and ad-hoc querying to its companion apps. It is the
tool you point at a freshly loaded or ETL'd schema to answer "is this actually OMOP, and
where is it wrong?" before any analysis begins.

Supports OMOP CDM v5.3 and v5.4. The version is auto-detected from `vocabulary.cdm_version`
where present, with a manual override if detection is inconclusive.

---

## What it does

The app is a four-step workflow, one tab per step:

| Step | Purpose |
|------|---------|
| **1. Detect** | Point at a schema. The app probes it for OMOP CDM tables (a schema with six or more matches is treated as OMOP-shaped), reads `vocabulary.cdm_version` to identify the CDM version, and lists every table with its column count and whether it belongs to the CDM spec. A manual version selector is available if auto-detection cannot resolve a version. |
| **2. Validate** | Compare the schema against the resolved spec. Findings are categorised as wrong type, missing column, missing table, extra column, or OK, and shown in a filterable table. Type checks compare by category (`integer / numeric / text / date / timestamp`) rather than exact PostgreSQL type, so `int4`, `bigint`, and `integer` all satisfy the same expected category. |
| **3. Preview** | A remediation script generated from the wrong-type findings: one `ALTER TABLE ... ALTER COLUMN ... TYPE ... USING ...` per fixable column, grouped by table, the whole thing wrapped in a single transaction. Conversions that cannot be done safely (for example boolean to date) appear as commented-out warnings flagged for manual review, not as live statements. The script can be downloaded and reviewed line by line. |
| **4. Execute** | Apply the script against the schema. Execution is gated behind a confirmation dialog that requires typing the schema name, and runs all `ALTER` statements inside one transaction so any single failure rolls everything back and leaves the schema unchanged. If the connected role lacks `ALTER` privileges the script fails cleanly and reports which statements were affected. |

---

## How it runs in the DRE

The validator is written around the workspace runtime, which differs from a standard R
installation in ways that make several conventional patterns silently fail:

- **Network-isolated.** No CRAN, no GitHub, no external APIs reach a workspace. The app
  never calls `install.packages()`; it checks for its required packages with
  `requireNamespace()` and stops with a clear message if any are missing.
- **Database connection via `xaputils::xap.conn`.** This active binding exposes the
  workspace PostgreSQL connection. It is referenced inline at every call, never captured
  to a local variable, because the underlying pointer can go stale between evaluations.
- **PostgreSQL column-case handling.** RPostgreSQL returns column headers in their stored
  case, which varies between datasets. Results are lowercased on the way back, and the
  actual stored names are looked up from `information_schema.columns` so identifiers are
  quoted correctly in the generated DDL.
- **DDL success is tested by shape, not null.** `dbGetQuery` returns a zero-column data
  frame, not `NULL`, for a DDL statement, so success is checked with `ncol(result) == 0`.
- **Single-file `app.R`.** The platform deploys a single file named `app.R`.
- **File outputs under `/home/workspace/files/`.** The downloaded fix script is mirrored
  to `/home/workspace/files/Downloads/` in addition to the in-browser download, because
  the workspace file manager only shows files on disk.

---

## Requirements

All packages are pre-installed at workspace creation. Nothing is installed at runtime. If a
required package is missing the app stops at startup with a clear message.

| Package | Purpose |
|---------|---------|
| shiny, shinydashboard | Application framework and layout |
| DT | Filterable findings and table-inventory views |
| DBI | Database interface |

There are no optional layers. The validator runs entirely on native SQL against the
workspace database.

---

## Type remediation, in detail

The generated script is conservative by design. A few specifics worth knowing before you run it:

- **Category-based, idempotent.** Only columns whose stored type category differs from the
  spec are altered. Columns that already match (in any equivalent PostgreSQL type) are left
  alone.
- **Explicit `USING` conversions.** Each `ALTER COLUMN ... TYPE` carries a `USING` clause
  appropriate to the source and target categories: text to integer strips non-numeric
  characters before casting, numeric to integer rounds, date to timestamp and back cast
  directly, and so on. Nothing relies on PostgreSQL's implicit coercion.
- **Unsafe conversions are skipped, not forced.** Where no meaningful conversion exists
  (boolean to date, for instance) the script emits a comment explaining why and marks the
  column for manual review and upstream correction.
- **All-or-nothing.** The whole script runs in one `BEGIN ... COMMIT`. A failure on any
  statement rolls the entire transaction back, so the schema is never left half-fixed.
- **Reversibility caveat.** Column type changes cannot always be reversed automatically.
  The Execute tab makes this explicit and recommends downloading and reviewing the script
  before applying it.

---

## Deployment

1. Develop in the workspace with `shiny::runApp("app.R")`.
2. The app must be a single file named `app.R` for platform-managed deployment.
3. The platform launches it with `R -e 'shiny::runApp("app.R", port=8080, host="0.0.0.0")'`,
   with no inherited R options.
4. Logs are viewable through the workspace app-management UI; `message(...)` output appears
   there.

The connected database role needs read access to `information_schema` and the target schema
for detection and validation, and `ALTER` privileges on the relevant tables for the Execute
step. Detection, validation, preview, and download work read-only; only Execute writes.

---

## Local development

Outside a workspace there is no `xaputils`, so the app falls back to a "no connection" state
and still launches, which is enough to check the UI and confirm the file parses. Validation
and remediation need a real OMOP schema, so do that work inside a workspace.

---

## Companion apps

The validator is one of a small set of single-file DRE apps that share the same conventions:

| App | Role |
|-----|------|
| **OMOP CDM Validator** (this app) | Conformance checking and column type remediation. |
| **OMOP Cohort Builder** | Build, validate, and analyse cohorts over a conformant OMOP schema. |
| **SQL Workbench** | Generic PostgreSQL schema browser, table inspector, and SQL editor for any workspace schema. |

The division is deliberate: the validator gets a schema into shape, the workbench is the
general-purpose query tool, and the cohort builder does the OMOP-specific analysis once the
schema is sound.

---

## Repository layout

| File | Purpose |
|------|---------|
| `app.R` | The application. Single-file Shiny app, deployed as-is to the workspace. |
| `reference-*.md` | Internal reference notes (DRE constraints, OMOP, Shiny patterns). |

---

## Governance and compliance

The validator is a community app running inside the Aridhia DRE. The environment carries a
96% SATRE score and ISO 27001, ISO 27701, HITRUST, and Cyber Essentials Plus certification.
Schema changes happen in place against the workspace database; nothing leaves the governed
environment, and the Execute step is gated behind explicit, typed confirmation and a
transaction so changes are auditable and reversible as a unit.
