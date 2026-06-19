# OMOP Cohort Builder for Aridhia DRE

A single-file R Shiny application for building, validating, and analysing patient
cohorts over an OMOP CDM database, deployed inside an Aridhia Digital Research
Environment (DRE) Project Workspace. It reads OMOP data straight from the workspace
PostgreSQL database, lets a researcher define a cohort from inclusion and exclusion
criteria, then runs characterisation, survival, incidence, and Cox analyses against
that cohort, with all compute happening server-side next to the data.

The app runs its own hand-built analyses in native SQL and, where the OHDSI R packages
are present, runs the community-standard implementations alongside them as an independent
second opinion. Natural-language cohort drafting and an AI phenotype review are available
through Aira when the workspace exposes it.

Supports OMOP CDM v5.3 and v5.4. The CDM version is auto-detected from
`vocabulary.cdm_version` where present.

---

## What it does

The app is organised as a workflow spine, reflected in the sidebar groups:

| Stage | Purpose |
|-------|---------|
| **Concepts** | Explore an OMOP schema: clinical tables, vocabulary, concept sets, descendant expansion. Multi-schema browsing with per-schema pills and a schema-overlap Venn. Outcome and concept pickers annotate each candidate with how many of the cohort's own patients have records, so high-yield concepts surface first. |
| **Define** | Build a cohort from inclusion and exclusion criteria around an index (entry) event. Live person count updates as criteria change. Cohort definitions save and load as JSON and reproduce against any compatible OMOP schema. |
| **Validate** | The "is this the right cohort?" checkpoint: orphan-concept scan, sequential attrition waterfall, index-event breakdown, a cohort overview (persons, female %, median age at index, median follow-up), and an optional Aira phenotype review grounded in those diagnostics. |
| **Analyse** | Native analyses computed directly in SQL: Kaplan-Meier survival, competing-risks cumulative incidence, Cox models, crude incidence rate, and cohort characterisation. Standards-layer cross-checks render beside the native results where the OHDSI packages are available. |
| **Export** | Cohort manifest written server-side as a full OMOP CDM schema (clinical and vocabulary tables plus the standard OHDSI cohort triple), CSV and SQL export, and a reproducible cohort definition. Everything mirrors to the workspace Downloads folder. |

### Distinctive analyses

These are the parts that are not just the OHDSI ecosystem in a wrapper:

- **Native-versus-standards cross-checking.** The app's own KM curve and the
  CohortSurvival estimate render side by side, so the two can be checked against each
  other. Every result comes with a second opinion.
- **First occurrence versus recurrence as an explicit choice.** Time-to-event and
  incidence questions hinge on whether you count a patient's first-ever onset or any
  occurrence after entry. The app makes this an explicit toggle with plain-language
  guidance rather than a buried default.
- **Incidence plotted against recurrence as two arms on one chart.** A survival curve
  stratified by prior history, with the new-onset arm and the recurrence arm side by
  side. The gap between the curves is the effect of prior history on time-to-event.
- **A discovery-oriented outcome picker.** Before an outcome concept is selected, the
  picker shows, per candidate concept, how many of the cohort's patients experience it
  after index, colour-coded and sorted so empty or meaningless curves are avoided up front.

---

## How it runs in the DRE

cohortbuilder is built for the workspace runtime, which differs from a standard R
installation in ways that make several conventional patterns silently fail. The app is
written around those constraints:

- **Network-isolated.** No CRAN, no GitHub, no external APIs reach a workspace. All data
  comes from the workspace PostgreSQL database. The app never calls `install.packages()`;
  it checks for required packages with `requireNamespace()` and stops with a clear message
  if any are missing.
- **Database connection via `xaputils::xap.conn`.** This is an active binding exposing the
  workspace PostgreSQL connection. It is referenced inline at every database call, never
  captured to a local variable, because the underlying pointer can go stale between
  evaluations.
- **PostgreSQL column-case handling.** RPostgreSQL returns column headers in the case they
  were stored, which varies between datasets (Synthea lowercase, MIMIC after ETL uppercase).
  Results are lowercased on the way back and a per-schema `col_map` resolves identifiers,
  so the same query works across datasets.
- **Single-file `app.R`.** The platform deploys a single file named `app.R`. The app is one
  file by design, with a clean internal separation between the native SQL core and the
  optional OHDSI Tools layer.
- **File outputs under `/home/workspace/files/`.** Every export is mirrored to
  `/home/workspace/files/Downloads/` in addition to the in-browser download, because the
  workspace file manager only shows files on disk.

---

## Requirements

All packages are pre-installed at workspace creation. Nothing is installed at runtime. If a
required package is missing the app stops at startup with a message to contact the workspace
administrator.

### Required

| Package | Purpose |
|---------|---------|
| shiny, shinydashboard | Application framework and layout |
| DT | Interactive tables |
| DBI | Database interface |
| ggplot2, scales | Plotting |
| survival, survminer | Kaplan-Meier and Cox estimation |
| broom | Tidying model output |
| car | Regression diagnostics |
| jsonlite | Cohort-definition serialisation |

### Optional: OHDSI standards layer

The OHDSI Tools features are additive. When these packages are absent the app runs
identically and the standards panels show a "not installed" state. This layer opens a
second connection to the same database via RPostgres, since the OHDSI stack needs the
modern DBI surface that the legacy `xap.conn` driver does not provide.

| Package | Purpose |
|---------|---------|
| RPostgres | DBI driver the OHDSI stack drives through dbplyr |
| CDMConnector, omopgenerics | Build a `cdm_reference` from the connection |
| CohortSurvival | Standards Kaplan-Meier, shown beside the native curve |
| IncidencePrevalence | Within-cohort incidence rates and period prevalence |
| PhenotypeR | Cohort diagnostics: counts, attrition, large-scale characterisation |
| CodelistGenerator | Concept-set code-use checks against the cohort's data |
| OmopSketch, CohortCharacteristics | Database and cohort profiling and characterisation |
| visOmopResults, gt | Tables and plots over `summarised_result` objects |

A fuller OHDSI manifest (CohortConstructor, PatientProfiles, DrugUtilisation,
CohortSymmetry, MeasurementDiagnostics, and the local-test packages omock, duckdb,
Eunomia) is listed in `omopdependencies.R` for workspaces that provision the complete suite.

### Optional: Aira (natural language)

| Package | Purpose |
|---------|---------|
| ellmer | Aira/OpenAI-compatible LLM client for R |
| promises, future | Asynchronous drafting so the UI stays responsive |

When any of these, or Aira itself, is unavailable, the natural-language features are hidden
from the UI rather than showing a broken control.

---

## Environment variables

| Variable | Required | Purpose |
|----------|----------|---------|
| `WORKSPACE_API_KEY` | For Aira only | API key for the Aira gateway, read by the deployed app's R process. The native and OHDSI features do not need it. |
| `TZ` | No | Defaults to `UTC` if unset. RPostgres date handling fails without a valid timezone; a deliberately configured workspace `TZ` is never overridden. |

---

## Aira integration

Two AI-assisted features run through Aira, the in-environment inference gateway, using the
`ellmer` client. Both are off unless the packages and `WORKSPACE_API_KEY` are present, and
both are designed so no patient-level data leaves the workspace.

**Natural-language cohort drafting (Define).** A plain-English description is turned into a
draft cohort definition, which the researcher then reviews and edits. Prompts are frozen and
versioned: once a prompt ships it is never edited, only superseded.

**Phenotype review (Validate).** A senior-reviewer critique of the cohort, drawn from the
Validate diagnostics. Only aggregate counts are sent to the model. The output is a markdown
critique with an explicit reminder to verify any cited concept IDs before acting on them.

The Aira endpoint and key are resolved from the workspace environment at startup. The gate
decision (packages present, key present, enabled) is logged on launch so an unavailable
feature can be diagnosed from the app logs.

---

## The OHDSI standards layer

Because the workspace exposes the OHDSI R packages directly, the app runs them server-side
and renders their output next to its own:

- **CohortSurvival** for a standards KM estimate beside the native curve.
- **IncidencePrevalence** for within-cohort incidence and period prevalence, with the cohort
  itself as the denominator.
- **PhenotypeR** for cohort diagnostics and large-scale characterisation stratified by age
  and sex.
- **CodelistGenerator** for concept-set code-use checks against the cohort's real data.
- **OmopSketch and CohortCharacteristics** for database and cohort profiling tables.

This is a deliberate interoperability demonstration. It is confined to the OHDSI Tools layer
and never touches the native SQL core.

---

## Test datasets

The app has been exercised against:

| Dataset | Notes |
|---------|-------|
| EUNOMIA / GiBleed | ~2,600 persons. The default development dataset. |
| Synthea | Synthetic records, lowercase column storage. |
| MIMIC-5 | `person_id` is BIGINT (handled via safe numeric coercion). Mapped to source vocabularies; standard OMOP concepts may be absent, which the orphan scan reports honestly rather than failing. |

---

## Exporting work

Two units of export, for two different purposes:

- **Cohort definition (JSON).** The right unit for sharing a cohort with a collaborator. It
  reproduces against any compatible OMOP schema. The person list itself is specific to one
  schema's data.
- **Cohort manifest (schema).** A full OMOP CDM written server-side via
  `CREATE TABLE AS SELECT`, including the standard OHDSI cohort triple, so the materialised
  cohort can be re-loaded, validated, and analysed without an interactive definition.

CSV and SQL exports are also available. Every file is written to
`/home/workspace/files/Downloads/` so it appears in the workspace file manager, in addition
to the in-browser download. Taking any data out of the workspace goes through the standard
airlock and egress review; the app writes to the workspace, it does not bypass governance.

---

## Deployment

1. Develop in the workspace with `shiny::runApp("app.R")`.
2. The app must be a single file named `app.R` for platform-managed deployment.
3. The platform launches it with `R -e 'shiny::runApp("app.R", port=8080, host="0.0.0.0")'`,
   with no inherited R options. Configuration reaches the deployed process only through
   environment variables and hardcoded defaults, not `options()`.
4. Logs are viewable through the workspace app-management UI. `message(...)` output, including
   the startup status dump for Aira and the OHDSI layer, appears there.

---

## Local development

Outside a workspace there is no `xaputils`, so the app falls back to a "no connection" state
and still launches, which is enough to check UI and parse cleanly. For analysis work against
real data, develop inside a workspace with a CDM loaded.

An automated test suite is planned around `omock` (mock OMOP CDM data) and `duckdb`, with
`Eunomia` for example datasets. These are listed in `omopdependencies.R`.

---

## Repository layout

| File | Purpose |
|------|---------|
| `app.R` | The application. Single-file Shiny app, deployed as-is to the workspace. |
| `omopdependencies.R` | Package-provisioning manifest for the OHDSI standards layer and the test suite. |
| `cohort_report.Rmd` | RMarkdown report template for a built cohort. |
| `omop_validator.R` | Companion app: OMOP CDM conformance and type validation. |
| `sql_workbench.R` | Companion app: generic PostgreSQL schema browser and SQL editor. |
| `reference-*.md` | Internal reference notes (DRE constraints, OMOP, Aira, Shiny patterns). |
| `cohortbuilder_v10_walkthrough.html` | End-to-end walkthrough for someone fluent in OMOP opening the app for the first time. |

---

## Governance and compliance

cohortbuilder is a community app running inside the Aridhia DRE. The environment carries a
96% SATRE score and ISO 27001, ISO 27701, HITRUST, and Cyber Essentials Plus certification.
The design principle throughout is that analysis is co-located with the data: the researcher
gets standards-grade methods with the immediacy of working next to the data, without anything
leaving the governed environment except through airlock review.
