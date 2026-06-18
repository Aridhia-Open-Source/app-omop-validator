# ══════════════════════════════════════════════════════════════════════════════
#  Aridhia DRE - OMOP CDM Validator
#  Single-file Shiny app for deployment to a DRE Project Workspace
#
#  Launch:  shiny::runApp("app.R")
#
#  Purpose: Point at a PostgreSQL schema, determine whether it conforms to the
#  OMOP CDM, identify column type mismatches against the spec, generate a
#  remediation SQL script, preview it, and (with explicit confirmation) execute
#  it inside a transaction.
#
#  Supports OMOP CDM v5.3 and v5.4. Version is auto-detected from
#  vocabulary.cdm_version where present.
#
#  Requires xaputils (pre-installed in all DRE workspace R environments).
# ══════════════════════════════════════════════════════════════════════════════


# ── 1. PACKAGE CHECKS ─────────────────────────────────────────────────────────

required_packages <- c("shiny", "shinydashboard", "DT", "DBI")

for (pkg in required_packages) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    stop(
      paste0("Required package '", pkg, "' is not installed. ",
             "Please install it in your workspace before launching this app."),
      call. = FALSE
    )
  }
}

suppressPackageStartupMessages({
  library(shiny)
  library(shinydashboard)
  library(DT)
  library(DBI)
})


# ── 2. CONSTANTS ──────────────────────────────────────────────────────────────

WORKSPACE_FILES <- if (dir.exists("/home/workspace/files")) {
  "/home/workspace/files"
} else {
  path.expand("~")
}
DOWNLOADS_DIR <- file.path(WORKSPACE_FILES, "Downloads")

# Canonical CDM table list - used for OMOP detection. A schema with 6+ matches
# is treated as OMOP-shaped.
OMOP_CDM_TABLES <- c(
  "person", "observation_period", "visit_occurrence", "visit_detail",
  "condition_occurrence", "drug_exposure", "procedure_occurrence",
  "device_exposure", "measurement", "observation", "death", "note",
  "note_nlp", "specimen", "fact_relationship", "location", "care_site",
  "provider", "payer_plan_period", "cost", "drug_era", "dose_era",
  "condition_era", "episode", "episode_event", "metadata",
  "concept", "vocabulary", "concept_relationship", "concept_ancestor",
  "concept_synonym", "domain", "concept_class", "relationship",
  "source_to_concept_map", "drug_strength", "cohort", "cohort_definition",
  "attribute_definition", "cdm_source"
)

# Tables required for col_map style queries (kept for parity with other apps).
TABLES_OF_INTEREST <- c(
  "vocabulary", "concept", "cdm_source", "person"
)

# Version-specific table sets - used to flag tables the spec expects but the
# schema doesn't have, and to skip tables that don't apply to a given version.
OMOP_TABLES_V5_3 <- c(
  "person", "observation_period", "visit_occurrence", "visit_detail",
  "condition_occurrence", "drug_exposure", "procedure_occurrence",
  "device_exposure", "measurement", "observation", "death", "note",
  "note_nlp", "specimen", "fact_relationship", "location", "care_site",
  "provider", "payer_plan_period", "cost", "drug_era", "dose_era",
  "condition_era", "concept", "vocabulary", "concept_relationship",
  "concept_ancestor", "concept_synonym", "domain", "concept_class",
  "relationship", "source_to_concept_map", "drug_strength",
  "cohort_definition", "attribute_definition", "cdm_source"
)

OMOP_TABLES_V5_4 <- c(
  "person", "observation_period", "visit_occurrence", "visit_detail",
  "condition_occurrence", "drug_exposure", "procedure_occurrence",
  "device_exposure", "measurement", "observation", "death", "note",
  "note_nlp", "specimen", "fact_relationship", "location", "care_site",
  "provider", "payer_plan_period", "cost", "drug_era", "dose_era",
  "condition_era", "episode", "episode_event", "metadata",
  "concept", "vocabulary", "concept_relationship", "concept_ancestor",
  "concept_synonym", "domain", "concept_class", "relationship",
  "source_to_concept_map", "drug_strength", "cdm_source"
)


# ── OMOP CDM expected column type categories (shared base - applies to v5.3
# and v5.4 unless overridden below). Values are categories
# (integer / numeric / text / date / timestamp) so we can compare against the
# actual PostgreSQL type without being brittle about the exact stored type
# (int4 vs bigint vs integer are all "integer").
OMOP_CDM_BASE <- list(

  person = list(
    person_id = "integer", gender_concept_id = "integer",
    year_of_birth = "integer", month_of_birth = "integer",
    day_of_birth = "integer", birth_datetime = "timestamp",
    race_concept_id = "integer", ethnicity_concept_id = "integer",
    location_id = "integer", provider_id = "integer",
    care_site_id = "integer", person_source_value = "text",
    gender_source_value = "text", gender_source_concept_id = "integer",
    race_source_value = "text", race_source_concept_id = "integer",
    ethnicity_source_value = "text", ethnicity_source_concept_id = "integer"
  ),

  observation_period = list(
    observation_period_id = "integer", person_id = "integer",
    observation_period_start_date = "date", observation_period_end_date = "date",
    period_type_concept_id = "integer"
  ),

  visit_occurrence = list(
    visit_occurrence_id = "integer", person_id = "integer",
    visit_concept_id = "integer", visit_start_date = "date",
    visit_start_datetime = "timestamp", visit_end_date = "date",
    visit_end_datetime = "timestamp", visit_type_concept_id = "integer",
    provider_id = "integer", care_site_id = "integer",
    visit_source_value = "text", visit_source_concept_id = "integer",
    preceding_visit_occurrence_id = "integer"
  ),

  visit_detail = list(
    visit_detail_id = "integer", person_id = "integer",
    visit_detail_concept_id = "integer", visit_detail_start_date = "date",
    visit_detail_start_datetime = "timestamp", visit_detail_end_date = "date",
    visit_detail_end_datetime = "timestamp", visit_detail_type_concept_id = "integer",
    provider_id = "integer", care_site_id = "integer",
    preceding_visit_detail_id = "integer", visit_detail_source_value = "text",
    visit_detail_source_concept_id = "integer", visit_occurrence_id = "integer"
  ),

  condition_occurrence = list(
    condition_occurrence_id = "integer", person_id = "integer",
    condition_concept_id = "integer", condition_start_date = "date",
    condition_start_datetime = "timestamp", condition_end_date = "date",
    condition_end_datetime = "timestamp", condition_type_concept_id = "integer",
    condition_status_concept_id = "integer", stop_reason = "text",
    provider_id = "integer", visit_occurrence_id = "integer",
    visit_detail_id = "integer", condition_source_value = "text",
    condition_source_concept_id = "integer", condition_status_source_value = "text"
  ),

  drug_exposure = list(
    drug_exposure_id = "integer", person_id = "integer",
    drug_concept_id = "integer", drug_exposure_start_date = "date",
    drug_exposure_start_datetime = "timestamp", drug_exposure_end_date = "date",
    drug_exposure_end_datetime = "timestamp", verbatim_end_date = "date",
    drug_type_concept_id = "integer", stop_reason = "text",
    refills = "integer", quantity = "numeric", days_supply = "integer",
    sig = "text", route_concept_id = "integer", lot_number = "text",
    provider_id = "integer", visit_occurrence_id = "integer",
    visit_detail_id = "integer", drug_source_value = "text",
    drug_source_concept_id = "integer", route_source_value = "text",
    dose_unit_source_value = "text"
  ),

  procedure_occurrence = list(
    procedure_occurrence_id = "integer", person_id = "integer",
    procedure_concept_id = "integer", procedure_date = "date",
    procedure_datetime = "timestamp", procedure_type_concept_id = "integer",
    modifier_concept_id = "integer", quantity = "integer",
    provider_id = "integer", visit_occurrence_id = "integer",
    visit_detail_id = "integer", procedure_source_value = "text",
    procedure_source_concept_id = "integer", modifier_source_value = "text"
  ),

  device_exposure = list(
    device_exposure_id = "integer", person_id = "integer",
    device_concept_id = "integer", device_exposure_start_date = "date",
    device_exposure_start_datetime = "timestamp", device_exposure_end_date = "date",
    device_exposure_end_datetime = "timestamp", device_type_concept_id = "integer",
    unique_device_id = "text", quantity = "integer",
    provider_id = "integer", visit_occurrence_id = "integer",
    visit_detail_id = "integer", device_source_value = "text",
    device_source_concept_id = "integer"
  ),

  measurement = list(
    measurement_id = "integer", person_id = "integer",
    measurement_concept_id = "integer", measurement_date = "date",
    measurement_datetime = "timestamp", measurement_time = "text",
    measurement_type_concept_id = "integer", operator_concept_id = "integer",
    value_as_number = "numeric", value_as_concept_id = "integer",
    unit_concept_id = "integer", range_low = "numeric", range_high = "numeric",
    provider_id = "integer", visit_occurrence_id = "integer",
    visit_detail_id = "integer", measurement_source_value = "text",
    measurement_source_concept_id = "integer", unit_source_value = "text",
    value_source_value = "text"
  ),

  observation = list(
    observation_id = "integer", person_id = "integer",
    observation_concept_id = "integer", observation_date = "date",
    observation_datetime = "timestamp", observation_type_concept_id = "integer",
    value_as_number = "numeric", value_as_string = "text",
    value_as_concept_id = "integer", qualifier_concept_id = "integer",
    unit_concept_id = "integer", provider_id = "integer",
    visit_occurrence_id = "integer", visit_detail_id = "integer",
    observation_source_value = "text", observation_source_concept_id = "integer",
    unit_source_value = "text", qualifier_source_value = "text"
  ),

  death = list(
    person_id = "integer", death_date = "date", death_datetime = "timestamp",
    death_type_concept_id = "integer", cause_concept_id = "integer",
    cause_source_value = "text", cause_source_concept_id = "integer"
  ),

  note = list(
    note_id = "integer", person_id = "integer", note_date = "date",
    note_datetime = "timestamp", note_type_concept_id = "integer",
    note_class_concept_id = "integer", note_title = "text",
    note_text = "text", encoding_concept_id = "integer",
    language_concept_id = "integer", provider_id = "integer",
    visit_occurrence_id = "integer", visit_detail_id = "integer",
    note_source_value = "text"
  ),

  note_nlp = list(
    note_nlp_id = "integer", note_id = "integer",
    section_concept_id = "integer", snippet = "text",
    "offset" = "text", lexical_variant = "text",
    note_nlp_concept_id = "integer", note_nlp_source_concept_id = "integer",
    nlp_system = "text", nlp_date = "date", nlp_datetime = "timestamp",
    term_exists = "text", term_temporal = "text", term_modifiers = "text"
  ),

  specimen = list(
    specimen_id = "integer", person_id = "integer",
    specimen_concept_id = "integer", specimen_type_concept_id = "integer",
    specimen_date = "date", specimen_datetime = "timestamp",
    quantity = "numeric", unit_concept_id = "integer",
    anatomic_site_concept_id = "integer", disease_status_concept_id = "integer",
    specimen_source_id = "text", specimen_source_value = "text",
    unit_source_value = "text", anatomic_site_source_value = "text",
    disease_status_source_value = "text"
  ),

  fact_relationship = list(
    domain_concept_id_1 = "integer", fact_id_1 = "integer",
    domain_concept_id_2 = "integer", fact_id_2 = "integer",
    relationship_concept_id = "integer"
  ),

  location = list(
    location_id = "integer", address_1 = "text", address_2 = "text",
    city = "text", state = "text", zip = "text", county = "text",
    location_source_value = "text", country_concept_id = "integer",
    country_source_value = "text", latitude = "numeric", longitude = "numeric"
  ),

  care_site = list(
    care_site_id = "integer", care_site_name = "text",
    place_of_service_concept_id = "integer", location_id = "integer",
    care_site_source_value = "text", place_of_service_source_value = "text"
  ),

  provider = list(
    provider_id = "integer", provider_name = "text", npi = "text",
    dea = "text", specialty_concept_id = "integer", care_site_id = "integer",
    year_of_birth = "integer", gender_concept_id = "integer",
    provider_source_value = "text", specialty_source_value = "text",
    specialty_source_concept_id = "integer", gender_source_value = "text",
    gender_source_concept_id = "integer"
  ),

  payer_plan_period = list(
    payer_plan_period_id = "integer", person_id = "integer",
    payer_plan_period_start_date = "date", payer_plan_period_end_date = "date",
    payer_concept_id = "integer", payer_source_value = "text",
    payer_source_concept_id = "integer", plan_concept_id = "integer",
    plan_source_value = "text", plan_source_concept_id = "integer",
    sponsor_concept_id = "integer", sponsor_source_value = "text",
    sponsor_source_concept_id = "integer", family_source_value = "text",
    stop_reason_concept_id = "integer", stop_reason_source_value = "text",
    stop_reason_source_concept_id = "integer"
  ),

  cost = list(
    cost_id = "integer", cost_event_id = "integer",
    cost_domain_id = "text", cost_type_concept_id = "integer",
    currency_concept_id = "integer", total_charge = "numeric",
    total_cost = "numeric", total_paid = "numeric", paid_by_payer = "numeric",
    paid_by_patient = "numeric", paid_patient_copay = "numeric",
    paid_patient_coinsurance = "numeric", paid_patient_deductible = "numeric",
    paid_by_primary = "numeric", paid_ingredient_cost = "numeric",
    paid_dispensing_fee = "numeric", payer_plan_period_id = "integer",
    amount_allowed = "numeric", revenue_code_concept_id = "integer",
    revenue_code_source_value = "text", drg_concept_id = "integer",
    drg_source_value = "text"
  ),

  drug_era = list(
    drug_era_id = "integer", person_id = "integer",
    drug_concept_id = "integer", drug_era_start_date = "date",
    drug_era_end_date = "date", drug_exposure_count = "integer",
    gap_days = "integer"
  ),

  dose_era = list(
    dose_era_id = "integer", person_id = "integer",
    drug_concept_id = "integer", unit_concept_id = "integer",
    dose_value = "numeric", dose_era_start_date = "date",
    dose_era_end_date = "date"
  ),

  condition_era = list(
    condition_era_id = "integer", person_id = "integer",
    condition_concept_id = "integer", condition_era_start_date = "date",
    condition_era_end_date = "date", condition_occurrence_count = "integer"
  ),

  concept = list(
    concept_id = "integer", concept_name = "text", domain_id = "text",
    vocabulary_id = "text", concept_class_id = "text",
    standard_concept = "text", concept_code = "text",
    valid_start_date = "date", valid_end_date = "date",
    invalid_reason = "text"
  ),

  vocabulary = list(
    vocabulary_id = "text", vocabulary_name = "text",
    vocabulary_reference = "text", vocabulary_version = "text",
    vocabulary_concept_id = "integer"
  ),

  domain = list(
    domain_id = "text", domain_name = "text", domain_concept_id = "integer"
  ),

  concept_class = list(
    concept_class_id = "text", concept_class_name = "text",
    concept_class_concept_id = "integer"
  ),

  relationship = list(
    relationship_id = "text", relationship_name = "text",
    is_hierarchical = "text", defines_ancestry = "text",
    reverse_relationship_id = "text", relationship_concept_id = "integer"
  ),

  concept_relationship = list(
    concept_id_1 = "integer", concept_id_2 = "integer",
    relationship_id = "text", valid_start_date = "date",
    valid_end_date = "date", invalid_reason = "text"
  ),

  concept_ancestor = list(
    ancestor_concept_id = "integer", descendant_concept_id = "integer",
    min_levels_of_separation = "integer", max_levels_of_separation = "integer"
  ),

  concept_synonym = list(
    concept_id = "integer", concept_synonym_name = "text",
    language_concept_id = "integer"
  ),

  source_to_concept_map = list(
    source_code = "text", source_concept_id = "integer",
    source_vocabulary_id = "text", source_code_description = "text",
    target_concept_id = "integer", target_vocabulary_id = "text",
    valid_start_date = "date", valid_end_date = "date",
    invalid_reason = "text"
  ),

  drug_strength = list(
    drug_concept_id = "integer", ingredient_concept_id = "integer",
    amount_value = "numeric", amount_unit_concept_id = "integer",
    numerator_value = "numeric", numerator_unit_concept_id = "integer",
    denominator_value = "numeric", denominator_unit_concept_id = "integer",
    box_size = "integer", valid_start_date = "date",
    valid_end_date = "date", invalid_reason = "text"
  ),

  cdm_source = list(
    cdm_source_name = "text", cdm_source_abbreviation = "text",
    cdm_holder = "text", source_description = "text",
    source_documentation_reference = "text", cdm_etl_reference = "text",
    source_release_date = "date", cdm_release_date = "date",
    cdm_version = "text", vocabulary_version = "text"
  )
)

# ── OMOP CDM v5.3 spec - base + v5.3-only tables, with v5.3 overrides
# v5.3 has these additional columns in visit_occurrence and visit_detail
# (admitting/discharge fields) which were renamed/restructured in v5.4.
OMOP_CDM_V5_3 <- {
  spec <- OMOP_CDM_BASE
  # v5.3 visit_occurrence has admitting_source_* / discharge_to_*
  spec$visit_occurrence <- c(spec$visit_occurrence, list(
    admitting_source_concept_id = "integer", admitting_source_value = "text",
    discharge_to_concept_id = "integer", discharge_to_source_value = "text"
  ))
  # v5.3 visit_detail has the same admitting/discharge fields
  spec$visit_detail <- c(spec$visit_detail, list(
    admitting_source_concept_id = "integer", admitting_source_value = "text",
    discharge_to_concept_id = "integer", discharge_to_source_value = "text"
  ))
  # v5.3 has cohort_definition and attribute_definition
  spec$cohort_definition <- list(
    cohort_definition_id = "integer", cohort_definition_name = "text",
    cohort_definition_description = "text",
    definition_type_concept_id = "integer", cohort_definition_syntax = "text",
    subject_concept_id = "integer", cohort_initiation_date = "date"
  )
  spec$attribute_definition <- list(
    cohort_definition_id = "integer", attribute_definition_id = "integer",
    attribute_name = "text", attribute_description = "text",
    attribute_type_concept_id = "integer", attribute_syntax = "text"
  )
  spec
}

# ── OMOP CDM v5.4 spec - base + v5.4-only tables (episode, episode_event,
# metadata) and v5.4 column changes.
OMOP_CDM_V5_4 <- {
  spec <- OMOP_CDM_BASE
  # v5.4 added episode, episode_event, metadata
  spec$episode <- list(
    episode_id = "integer", person_id = "integer",
    episode_concept_id = "integer", episode_start_date = "date",
    episode_start_datetime = "timestamp", episode_end_date = "date",
    episode_end_datetime = "timestamp",
    episode_parent_id = "integer", episode_number = "integer",
    episode_object_concept_id = "integer",
    episode_type_concept_id = "integer",
    episode_source_value = "text", episode_source_concept_id = "integer"
  )
  spec$episode_event <- list(
    episode_id = "integer", event_id = "integer",
    episode_event_field_concept_id = "integer"
  )
  spec$metadata <- list(
    metadata_concept_id = "integer", metadata_type_concept_id = "integer",
    name = "text", value_as_string = "text",
    value_as_concept_id = "integer", value_as_number = "numeric",
    metadata_date = "date", metadata_datetime = "timestamp"
  )
  # v5.4 person added race_source_concept_id (already in base)
  # v5.4 condition_occurrence added condition_status_source_value (already in base)
  # v5.4 measurement, observation: minor additions
  spec$measurement <- c(spec$measurement, list(
    unit_source_concept_id = "integer", measurement_event_id = "integer",
    meas_event_field_concept_id = "integer"
  ))
  spec$observation <- c(spec$observation, list(
    observation_event_id = "integer", obs_event_field_concept_id = "integer",
    value_as_datetime = "timestamp"
  ))
  # v5.4 note added note_event_id and note_event_field_concept_id
  spec$note <- c(spec$note, list(
    note_event_id = "integer", note_event_field_concept_id = "integer"
  ))
  spec
}


# ── 3. HELPERS ────────────────────────────────────────────────────────────────

`%||%` <- function(a, b) if (!is.null(a) && length(a) > 0) a else b
pg_str <- function(s) paste0("'", gsub("'", "''", as.character(s)), "'")
qq     <- function(x) sprintf('"%s"', x)
fq     <- function(schema, table) sprintf('"%s"."%s"', schema, table)

ensure_downloads <- function() {
  if (!dir.exists(DOWNLOADS_DIR)) {
    dir.create(DOWNLOADS_DIR, recursive = TRUE, showWarnings = FALSE)
  }
  DOWNLOADS_DIR
}


# ── 4. DATABASE CONNECTION ────────────────────────────────────────────────────

DRE_CONN <- tryCatch(
  { library(xaputils); message("[ omop_validator ] connected via xap.conn"); xap.conn },
  error = function(e) {
    message("[ omop_validator ] xaputils not available - no DB connection")
    NULL
  }
)

conn_valid <- function() !is.null(DRE_CONN)

db_query <- function(sql) {
  if (!conn_valid()) stop("No database connection.")
  result <- withCallingHandlers(
    DBI::dbGetQuery(DRE_CONN, sql),
    warning = function(w) {
      if (grepl("unrecognized PostgreSQL|unknown data type",
                conditionMessage(w), ignore.case = TRUE))
        invokeRestart("muffleWarning")
    }
  )
  if (is.data.frame(result) && ncol(result) > 0)
    names(result) <- tolower(names(result))
  result
}

db_execute <- function(sql) {
  if (!conn_valid()) stop("No database connection.")
  DBI::dbExecute(DRE_CONN, sql)
}


# ── 5. DATA ACCESS FUNCTIONS ──────────────────────────────────────────────────

# get_schemas uses xaputils::xap.conn directly so it always reflects the live
# connection state.
get_schemas <- function() {
  if (!requireNamespace("xaputils", quietly = TRUE)) return(character(0))
  conn <- tryCatch(xaputils::xap.conn, error = function(e) NULL)
  if (is.null(conn)) return(character(0))
  sql <- "SELECT nspname AS schema_name
          FROM pg_namespace
          WHERE nspname NOT LIKE 'pg_%'
            AND nspname NOT IN ('information_schema', 'public')
          ORDER BY nspname"
  r <- tryCatch(DBI::dbGetQuery(conn, sql), error = function(e) NULL)
  if (is.null(r) || nrow(r) == 0) return(character(0))
  names(r) <- tolower(names(r))
  r$schema_name
}

get_tables <- function(schema) {
  sql <- sprintf(
    "SELECT table_name FROM information_schema.tables
     WHERE table_schema = %s AND table_type = 'BASE TABLE'
     ORDER BY table_name",
    pg_str(schema))
  r <- tryCatch(db_query(sql), error = function(e) NULL)
  if (is.null(r) || nrow(r) == 0) return(character(0))
  r$table_name
}

# Bulk pull every column for the schema in one query - used for both col_map
# population and validation. Returns a data frame:
#   table_name (lowercase), column_name (actual case), data_type (lowercase)
get_columns_for_schema <- function(schema) {
  sql <- sprintf(
    "SELECT lower(table_name) AS table_name,
            column_name        AS column_name,
            lower(data_type)   AS data_type
       FROM information_schema.columns
      WHERE table_schema = %s
      ORDER BY table_name, ordinal_position",
    pg_str(schema))
  r <- tryCatch(db_query(sql), error = function(e) NULL)
  if (is.null(r) || nrow(r) == 0) {
    return(data.frame(table_name = character(0),
                      column_name = character(0),
                      data_type = character(0),
                      stringsAsFactors = FALSE))
  }
  r
}

# Build col_map from a get_columns_for_schema() result, restricted to the named
# tables. Same shape as in cohortbuilder/sql_workbench:
#   col_map[[table_lower]][[col_lower]] = actual_stored_name
build_col_map <- function(cols_df, tables_of_interest) {
  if (nrow(cols_df) == 0) return(list())
  filt <- cols_df[cols_df$table_name %in% tolower(tables_of_interest), , drop = FALSE]
  if (nrow(filt) == 0) return(list())
  result <- list()
  for (i in seq_len(nrow(filt))) {
    tbl <- filt$table_name[i]; col <- filt$column_name[i]
    if (is.null(result[[tbl]])) result[[tbl]] <- list()
    result[[tbl]][[tolower(col)]] <- col
  }
  result
}

ac <- function(col_map, table, col) {
  actual <- col_map[[tolower(table)]][[tolower(col)]]
  qq(actual %||% col)
}

# Convert a PostgreSQL data_type string to our 5-category system.
pg_type_to_cat <- function(pg_type) {
  pt <- tolower(trimws(pg_type %||% ""))
  if (grepl("^(int|bigint|smallint|integer|int4|int8|int2|serial|bigserial)", pt))
    return("integer")
  if (grepl("^(numeric|decimal|real|double|float|money)", pt))
    return("numeric")
  if (grepl("^(timestamp|timestamptz)", pt))
    return("timestamp")
  if (grepl("^date$", pt))
    return("date")
  if (grepl("^(char|varchar|text|name|bpchar|character)", pt))
    return("text")
  if (grepl("^bool", pt))
    return("boolean")
  "other"
}

# Detect whether a schema is OMOP-shaped and read cdm_version.
detect_omop <- function(schema) {
  tbls   <- tolower(get_tables(schema))
  hits   <- intersect(tbls, OMOP_CDM_TABLES)
  is_cdm <- length(hits) >= 6

  cdm_info        <- NULL
  vocab_version   <- NULL
  vocab_cdm_ver   <- NULL

  if (is_cdm && "cdm_source" %in% tbls) {
    cdm_info <- tryCatch(
      db_query(sprintf('SELECT * FROM %s.%s LIMIT 1', qq(schema), qq("cdm_source"))),
      error = function(e) NULL)
    if (!is.null(cdm_info) && nrow(cdm_info) > 0) {
      # Result has lowercased names already.
      if ("cdm_version" %in% names(cdm_info))
        vocab_cdm_ver <- as.character(cdm_info$cdm_version[1])
    }
  }

  # Fallback: vocabulary table sometimes carries a CDM version row, but more
  # often just vocabulary_version. Check vocabulary for a row keyed by
  # 'CDM_RELEASE' or similar - the OHDSI convention varies.
  if (is.null(vocab_cdm_ver) && is_cdm && "vocabulary" %in% tbls) {
    sql <- sprintf(
      "SELECT vocabulary_version
         FROM %s.vocabulary
        WHERE upper(vocabulary_id) IN ('CDM_RELEASE','CDM','OMOP CDM')
        LIMIT 1",
      qq(schema))
    vv <- tryCatch(db_query(sql), error = function(e) NULL)
    if (!is.null(vv) && nrow(vv) > 0)
      vocab_cdm_ver <- as.character(vv$vocabulary_version[1])
  }

  list(
    is_omop         = is_cdm,
    hit_count       = length(hits),
    hits            = hits,
    n_total         = length(tbls),
    cdm_info        = cdm_info,
    cdm_version_raw = vocab_cdm_ver
  )
}

# Normalise a raw cdm_version string (e.g. "v5.3.1", "5.4", "CDM v5.4 Release Candidate")
# to one of "v5.3", "v5.4", or NULL if unrecognised.
normalise_cdm_version <- function(raw) {
  if (is.null(raw) || is.na(raw) || !nzchar(raw)) return(NULL)
  s <- tolower(as.character(raw))
  if (grepl("5\\.4", s)) return("v5.4")
  if (grepl("5\\.3", s)) return("v5.3")
  NULL
}

# Compare an OMOP schema against a spec. Returns a list with:
#   findings: data frame of column-level findings
#   summary:  named integer vector of counts by status
#   tables:   per-table summary
#
# Status values:
#   ok           - column present, type matches expected category
#   wrong_type   - column present, type category mismatch (fixable via ALTER)
#   missing_col  - column expected but not present in the schema
#   extra_col    - column present but not in spec (informational; not fixed)
#   missing_tbl  - table expected but not present (informational; not fixed)
validate_schema <- function(schema, spec, cols_df) {
  spec_tables <- names(spec)
  schema_tables <- unique(cols_df$table_name)

  findings <- list()

  for (tbl in spec_tables) {
    expected_cols <- spec[[tbl]]
    if (!(tbl %in% schema_tables)) {
      findings[[length(findings) + 1L]] <- data.frame(
        table_name = tbl, column_name = NA_character_,
        actual_type = NA_character_, actual_cat = NA_character_,
        expected_cat = NA_character_, status = "missing_tbl",
        stringsAsFactors = FALSE)
      next
    }
    tbl_rows <- cols_df[cols_df$table_name == tbl, , drop = FALSE]
    actual_map <- setNames(tbl_rows$data_type, tolower(tbl_rows$column_name))
    actual_case_map <- setNames(tbl_rows$column_name, tolower(tbl_rows$column_name))

    expected_lc <- tolower(names(expected_cols))

    # Each expected column: ok, wrong_type, or missing_col
    for (i in seq_along(expected_cols)) {
      col_lc      <- tolower(names(expected_cols)[i])
      expected_ct <- expected_cols[[i]]
      if (col_lc %in% names(actual_map)) {
        actual_type <- actual_map[[col_lc]]
        actual_ct   <- pg_type_to_cat(actual_type)
        status      <- if (actual_ct == expected_ct) "ok" else "wrong_type"
        findings[[length(findings) + 1L]] <- data.frame(
          table_name = tbl,
          column_name = actual_case_map[[col_lc]],
          actual_type = actual_type,
          actual_cat  = actual_ct,
          expected_cat = expected_ct,
          status = status,
          stringsAsFactors = FALSE)
      } else {
        findings[[length(findings) + 1L]] <- data.frame(
          table_name = tbl,
          column_name = names(expected_cols)[i],
          actual_type = NA_character_,
          actual_cat  = NA_character_,
          expected_cat = expected_ct,
          status = "missing_col",
          stringsAsFactors = FALSE)
      }
    }

    # Each actual column not in spec: extra_col
    extras <- setdiff(tolower(tbl_rows$column_name), expected_lc)
    for (extra_lc in extras) {
      findings[[length(findings) + 1L]] <- data.frame(
        table_name = tbl,
        column_name = actual_case_map[[extra_lc]],
        actual_type = actual_map[[extra_lc]],
        actual_cat  = pg_type_to_cat(actual_map[[extra_lc]]),
        expected_cat = NA_character_,
        status = "extra_col",
        stringsAsFactors = FALSE)
    }
  }

  if (length(findings) == 0) {
    df <- data.frame(table_name = character(0), column_name = character(0),
                     actual_type = character(0), actual_cat = character(0),
                     expected_cat = character(0), status = character(0),
                     stringsAsFactors = FALSE)
  } else {
    df <- do.call(rbind, findings)
  }

  status_counts <- table(factor(df$status,
                                levels = c("ok","wrong_type","missing_col",
                                           "extra_col","missing_tbl")))
  list(
    findings = df,
    summary  = as.list(status_counts),
    n_tables_expected = length(spec_tables),
    n_tables_present  = sum(spec_tables %in% schema_tables)
  )
}


# ── 6. FIX SCRIPT GENERATION ──────────────────────────────────────────────────

# Build a single ALTER TABLE statement for one wrong-type column. Returns either
# an active SQL statement, or a comment-only block for cases that can't be
# safely auto-fixed (e.g. boolean → date).
make_alter <- function(schema, table, column,
                       actual_cat, expected_cat, actual_type) {
  qcol <- qq(column)
  qtbl <- fq(schema, table)

  target_type <- switch(expected_cat,
    integer   = "bigint",
    numeric   = "numeric",
    text      = "text",
    date      = "date",
    timestamp = "timestamp without time zone",
    "text"
  )

  if (actual_cat == "boolean") {
    if (expected_cat %in% c("date", "timestamp")) {
      return(paste0(
        "-- SKIPPED: ", schema, ".", table, ".", column,
        " is boolean but expected ", expected_cat, ".\n",
        "--   No meaningful boolean -> ", expected_cat, " conversion exists.\n",
        "--   This column requires manual review and upstream data correction.\n"))
    }
    using_clause <- switch(expected_cat,
      integer = paste0("CASE WHEN ", qcol, " THEN 1 ELSE 0 END"),
      numeric = paste0("CASE WHEN ", qcol, " THEN 1.0 ELSE 0.0 END"),
      text    = paste0(qcol, "::text"),
      paste0(qcol, "::", target_type)
    )
    return(paste0(
      "-- ", schema, ".", table, ".", column,
      " is boolean in DB but expected ", expected_cat,
      " per OMOP CDM spec.\n",
      "ALTER TABLE ", qtbl, "\n",
      "  ALTER COLUMN ", qcol, " TYPE ", target_type, "\n",
      "  USING ", using_clause, ";\n"))
  }

  using_expr <- if (actual_cat == "text" && expected_cat == "integer") {
    paste0("NULLIF(REGEXP_REPLACE(", qcol, ", '[^0-9-]', '', 'g'), '')::bigint")
  } else if (actual_cat == "text" && expected_cat == "numeric") {
    paste0("NULLIF(TRIM(", qcol, "), '')::numeric")
  } else if (actual_cat == "text" && expected_cat == "date") {
    paste0(qcol, "::date")
  } else if (actual_cat == "text" && expected_cat == "timestamp") {
    paste0(qcol, "::timestamp without time zone")
  } else if (actual_cat == "integer" && expected_cat == "numeric") {
    paste0(qcol, "::numeric")
  } else if (actual_cat == "numeric" && expected_cat == "integer") {
    paste0("ROUND(", qcol, ")::bigint")
  } else if (actual_cat == "integer" && expected_cat == "text") {
    paste0(qcol, "::text")
  } else if (actual_cat == "numeric" && expected_cat == "text") {
    paste0(qcol, "::text")
  } else if (actual_cat == "date" && expected_cat == "timestamp") {
    paste0(qcol, "::timestamp without time zone")
  } else if (actual_cat == "timestamp" && expected_cat == "date") {
    paste0(qcol, "::date")
  } else {
    paste0(qcol, "::", target_type)
  }

  paste0(
    "ALTER TABLE ", qtbl, "\n",
    "  ALTER COLUMN ", qcol, " TYPE ", target_type, "\n",
    "  USING ", using_expr, ";\n")
}

# Build the full fix script from a findings data frame. Returns a character
# vector - header lines + per-table ALTER statements + footer. Wraps all DDL
# in a transaction so a single failure rolls everything back.
build_fix_script <- function(schema, cdm_version, findings) {
  wrong <- findings[findings$status == "wrong_type", , drop = FALSE]

  header <- c(
    "-- ============================================================",
    sprintf("-- OMOP CDM Type Fix Script"),
    sprintf("-- Schema:      %s", schema),
    sprintf("-- CDM version: %s", cdm_version %||% "unknown"),
    sprintf("-- Generated:   %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")),
    sprintf("-- Statements:  %d", nrow(wrong)),
    "--",
    "-- All ALTER TABLE statements run inside a single transaction.",
    "-- If any statement fails, the entire transaction is rolled back.",
    "-- ============================================================",
    "",
    "BEGIN;",
    ""
  )

  if (nrow(wrong) == 0) {
    return(c(header,
             "-- No type mismatches found. Nothing to fix.",
             "",
             "COMMIT;"))
  }

  body <- character(0)
  for (tbl in unique(wrong$table_name)) {
    tbl_rows <- wrong[wrong$table_name == tbl, , drop = FALSE]
    body <- c(body,
              sprintf("-- -- %s (%d column%s) --",
                      tbl, nrow(tbl_rows),
                      if (nrow(tbl_rows) == 1) "" else "s"),
              "")
    for (i in seq_len(nrow(tbl_rows))) {
      body <- c(body,
                make_alter(
                  schema = schema, table = tbl,
                  column = tbl_rows$column_name[i],
                  actual_cat = tbl_rows$actual_cat[i],
                  expected_cat = tbl_rows$expected_cat[i],
                  actual_type = tbl_rows$actual_type[i]
                ),
                "")
    }
  }

  c(header, body, "COMMIT;")
}

# Split a multi-statement script into individual SQL statements for execution.
# Strips comment-only lines and blank lines. Treats the trailing semicolon as
# a separator. Returns a character vector of statements (no trailing ;).
split_sql_statements <- function(script_lines) {
  text <- paste(script_lines, collapse = "\n")
  # Remove line comments
  text <- gsub("--[^\n]*", "", text)
  # Split on semicolons
  parts <- strsplit(text, ";", fixed = TRUE)[[1]]
  parts <- trimws(parts)
  parts[nzchar(parts)]
}


# ── 7. UI ─────────────────────────────────────────────────────────────────────

ui <- dashboardPage(
  skin = "blue",
  dashboardHeader(title = "OMOP CDM Validator"),

  dashboardSidebar(
    width = 260,
    sidebarMenu(
      id = "tabs",
      menuItem("1. Detect",   tabName = "tab_detect",   icon = icon("search")),
      menuItem("2. Validate", tabName = "tab_validate", icon = icon("check-double")),
      menuItem("3. Preview",  tabName = "tab_preview",  icon = icon("file-code")),
      menuItem("4. Execute",  tabName = "tab_execute",  icon = icon("bolt"))
    ),
    tags$hr(style = "border-color: #2c3b41; margin: 10px 12px;"),
    div(style = "padding: 5px 12px;",
      tags$label("Target schema",
                 style = "color: #b8c7ce; font-size: 12px; font-weight: 600; margin-bottom: 4px;"),
      div(class = "schema-select-wrap",
        selectInput("schema_select", NULL,
                    choices = NULL, selected = NULL, width = "100%")
      ),
      actionButton("refresh_schemas", "Refresh",
                   icon = icon("sync"),
                   class = "btn-sm",
                   style = "width: 100%; margin-top: 4px; margin-bottom: 4px;")
    ),
    tags$hr(style = "border-color: #2c3b41; margin: 10px 12px;"),
    div(style = "padding: 5px 12px;",
      strong("Status", style = "color: #fff; font-size: 12px;"),
      uiOutput("sidebar_status")
    )
  ),

  dashboardBody(
    tags$head(
      tags$style(HTML("
        .content-wrapper, .right-side { background-color: #f4f6f9; }
        .box { border-top: 3px solid #3c8dbc; }
        .status-card {
          background: #fff; border: 1px solid #ddd; border-radius: 4px;
          padding: 12px; margin-bottom: 10px;
        }
        .status-card .label-row {
          display: flex; justify-content: space-between;
          padding: 4px 0; border-bottom: 1px solid #f0f0f0;
        }
        .status-card .label-row:last-child { border-bottom: none; }
        .status-pill {
          display: inline-block; padding: 2px 8px; border-radius: 10px;
          font-size: 11px; font-weight: 600; color: #fff;
        }
        .status-pill.ok    { background: #00a65a; }
        .status-pill.warn  { background: #f39c12; }
        .status-pill.bad   { background: #dd4b39; }
        .status-pill.info  { background: #3c8dbc; }
        .status-pill.muted { background: #999; }
        .sql-preview {
          background: #1e1e1e; color: #d4d4d4;
          font-family: 'Courier New', monospace; font-size: 12px;
          padding: 12px; border-radius: 4px;
          max-height: 600px; overflow: auto; white-space: pre;
        }
        .sql-preview .sql-comment { color: #6a9955; }
        .sql-preview .sql-keyword { color: #569cd6; font-weight: 600; }
        .findings-summary {
          display: flex; gap: 8px; flex-wrap: wrap;
          margin-bottom: 15px;
        }
        .findings-summary .stat {
          flex: 1; min-width: 120px;
          background: #fff; padding: 10px 12px; border-radius: 4px;
          border-left: 4px solid #3c8dbc;
          display: flex; align-items: baseline; gap: 10px;
        }
        .findings-summary .stat.ok    { border-left-color: #00a65a; }
        .findings-summary .stat.wrong { border-left-color: #dd4b39; }
        .findings-summary .stat.miss  { border-left-color: #f39c12; }
        .findings-summary .stat .num  {
          font-size: 22px; font-weight: 700; line-height: 1;
        }
        .findings-summary .stat .lbl  {
          font-size: 11px; color: #777; text-transform: uppercase;
          letter-spacing: 0.3px;
        }
        .skinny-btn { padding: 4px 10px; font-size: 12px; }
        .sidebar-status-line {
          color: #b8c7ce; font-size: 12px; padding: 3px 0;
          line-height: 1.4;
          word-break: break-word;
        }
        .sidebar-status-line strong { color: #fff; }
        .schema-select-wrap .selectize-input {
          min-height: 34px; padding: 6px 8px;
        }
        .schema-select-wrap .selectize-input .item {
          font-size: 13px;
        }
        .schema-select-wrap .selectize-dropdown {
          font-size: 13px;
        }
        .main-sidebar { transition: none; }
        .content-wrapper { padding-top: 5px; }
        .box-header > .box-title { font-size: 16px; }
        .radio-inline { margin-right: 12px; }
        .exec-log {
          background: #1e1e1e; color: #d4d4d4;
          font-family: 'Courier New', monospace; font-size: 12px;
          padding: 12px; border-radius: 4px;
          max-height: 500px; overflow: auto; white-space: pre-wrap;
        }
        .exec-log .ok-line   { color: #4ec9b0; }
        .exec-log .err-line  { color: #f48771; }
        .exec-log .head-line { color: #569cd6; font-weight: 600; }
      "))
    ),

    tabItems(

      # ── Tab 1: Detect ────────────────────────────────────────────────────
      tabItem(tabName = "tab_detect",
        fluidRow(
          box(width = 12, title = "Schema detection", status = "primary", solidHeader = TRUE,
            p("Pick a schema in the sidebar. The validator will check whether it ",
              "looks like an OMOP CDM by counting matches against the canonical ",
              "table list, and read ", tags$code("cdm_source"),
              " (or ", tags$code("vocabulary"), ") to determine the CDM version."),
            uiOutput("detect_summary"),
            br(),
            uiOutput("detect_proceed_ui")
          )
        ),
        fluidRow(
          box(width = 12, title = "Tables found", status = "info", solidHeader = TRUE,
            collapsible = TRUE, collapsed = TRUE,
            DT::DTOutput("detect_tables_dt")
          )
        )
      ),

      # ── Tab 2: Validate ──────────────────────────────────────────────────
      tabItem(tabName = "tab_validate",
        fluidRow(
          box(width = 12, title = "Run validation", status = "primary", solidHeader = TRUE,
            p("Compare every column in every CDM table against the spec for ",
              "the detected version. Type categories are compared (",
              tags$code("integer / numeric / text / date / timestamp"),
              ") rather than exact PostgreSQL types, so ",
              tags$code("int4"), ", ", tags$code("bigint"), ", and ",
              tags$code("integer"), " all match the same expected category."),
            div(style = "display: flex; gap: 10px; align-items: center;",
              actionButton("run_validation", "Run validation",
                           icon = icon("play"), class = "btn-primary"),
              uiOutput("validate_status_inline")
            )
          )
        ),
        fluidRow(
          column(12, uiOutput("findings_summary_ui"))
        ),
        fluidRow(
          box(width = 12, title = "Findings", status = "info", solidHeader = TRUE,
            div(style = "margin-bottom: 10px;",
              tags$label("Filter:",
                         style = "font-size: 12px; color: #555; margin-right: 8px;"),
              radioButtons("findings_filter", NULL,
                choices = c("All" = "all",
                            "Wrong type" = "wrong_type",
                            "Missing column" = "missing_col",
                            "Missing table" = "missing_tbl",
                            "Extra column" = "extra_col",
                            "OK" = "ok"),
                selected = "wrong_type", inline = TRUE)
            ),
            DT::DTOutput("findings_dt")
          )
        )
      ),

      # ── Tab 3: Preview ───────────────────────────────────────────────────
      tabItem(tabName = "tab_preview",
        fluidRow(
          box(width = 12, title = "Generated remediation script", status = "primary",
              solidHeader = TRUE,
            p("This script will be wrapped in a single transaction. If any ",
              "statement fails the entire transaction is rolled back, leaving ",
              "the schema unchanged. Statements that cannot be auto-converted ",
              "(e.g. boolean to date) appear as commented-out warnings."),
            div(style = "display: flex; gap: 10px; align-items: center; margin-bottom: 10px;",
              downloadButton("download_sql", "Download .sql",
                             class = "btn-default skinny-btn"),
              span(textOutput("preview_stats", inline = TRUE),
                   style = "color: #777; font-size: 12px; margin-left: 10px;")
            ),
            uiOutput("preview_sql_ui")
          )
        )
      ),

      # ── Tab 4: Execute ───────────────────────────────────────────────────
      tabItem(tabName = "tab_execute",
        fluidRow(
          box(width = 12, title = "Execute remediation script", status = "danger",
              solidHeader = TRUE,
            div(style = "background: #fff3cd; border-left: 4px solid #f39c12; padding: 12px; margin-bottom: 15px;",
              tags$h4(icon("exclamation-triangle"), " Read before executing",
                      style = "margin-top: 0;"),
              tags$ul(
                tags$li("This will run ", tags$code("ALTER TABLE"),
                        " statements against the schema. Column type changes ",
                        "cannot always be reversed automatically."),
                tags$li("Execution is wrapped in a transaction. Any failure ",
                        "rolls everything back."),
                tags$li("If your role lacks ", tags$code("ALTER"),
                        " privileges on these tables, the script will fail ",
                        "and report which statements were affected."),
                tags$li("Consider downloading the script first and reviewing ",
                        "it line-by-line before running here.")
              )
            ),
            uiOutput("execute_status_ui"),
            br(),
            actionButton("execute_btn", "Execute script",
                         icon = icon("bolt"), class = "btn-danger"),
            br(), br(),
            uiOutput("execution_log_ui")
          )
        )
      )

    )
  )
)


# ── 8. SERVER ─────────────────────────────────────────────────────────────────

server <- function(input, output, session) {

  # Reactive state - declared first, before any observers. Order matters:
  # all reactiveVal() calls precede all observeEvent / reactive blocks.
  col_map_rv         <- reactiveVal(list())
  cols_df_rv         <- reactiveVal(NULL)        # full information_schema.columns dump
  detection_rv       <- reactiveVal(NULL)        # output of detect_omop()
  cdm_version_rv     <- reactiveVal(NULL)        # "v5.3" / "v5.4" / NULL
  spec_rv            <- reactiveVal(NULL)        # the chosen spec list
  validation_rv      <- reactiveVal(NULL)        # output of validate_schema()
  sql_lines_rv       <- reactiveVal(NULL)        # character vector of script lines
  execution_rv       <- reactiveVal(NULL)        # list(state, started, finished, log)

  # Schemas dropdown - populate on startup and on refresh.
  refresh_schemas <- function() {
    schemas <- tryCatch(get_schemas(), error = function(e) character(0))
    updateSelectInput(session, "schema_select",
                      choices = c("(select a schema)" = "", schemas),
                      selected = "")
  }
  refresh_schemas()
  observeEvent(input$refresh_schemas, {
    refresh_schemas()
    showNotification("Schema list refreshed.", type = "message", duration = 2)
  })

  # Reset all downstream state when schema changes.
  observeEvent(input$schema_select, {
    col_map_rv(list())
    cols_df_rv(NULL)
    detection_rv(NULL)
    cdm_version_rv(NULL)
    spec_rv(NULL)
    validation_rv(NULL)
    sql_lines_rv(NULL)
    execution_rv(NULL)

    sch <- input$schema_select
    if (is.null(sch) || !nzchar(sch)) return()

    # Pull all columns for the schema once - used for col_map and validation.
    cols_df <- tryCatch(
      get_columns_for_schema(sch),
      error = function(e) {
        showNotification(paste("Could not read information_schema:", e$message),
                         type = "error")
        NULL
      }
    )
    req(!is.null(cols_df))
    cols_df_rv(cols_df)

    cm <- build_col_map(cols_df, TABLES_OF_INTEREST)
    col_map_rv(cm)

    # Run detection.
    det <- tryCatch(detect_omop(sch),
                    error = function(e) {
                      showNotification(paste("Detection failed:", e$message),
                                       type = "error")
                      NULL
                    })
    req(!is.null(det))
    detection_rv(det)

    # Resolve CDM version: prefer cdm_source.cdm_version → vocabulary fallback.
    ver <- normalise_cdm_version(det$cdm_version_raw)
    cdm_version_rv(ver)
    if (!is.null(ver)) {
      spec_rv(if (ver == "v5.4") OMOP_CDM_V5_4 else OMOP_CDM_V5_3)
    }
  }, ignoreInit = TRUE)

  # ── Sidebar status panel ───────────────────────────────────────────────
  output$sidebar_status <- renderUI({
    sch <- input$schema_select
    if (is.null(sch) || !nzchar(sch)) {
      return(div(class = "sidebar-status-line", "No schema selected."))
    }
    det <- detection_rv()
    ver <- cdm_version_rv()
    val <- validation_rv()

    lines <- list(
      div(class = "sidebar-status-line",
          strong("Schema: "), sch)
    )
    if (!is.null(det)) {
      lines <- c(lines, list(
        div(class = "sidebar-status-line",
            strong("Tables: "), det$n_total,
            sprintf(" (%d CDM)", det$hit_count))
      ))
      omop_tag <- if (det$is_omop)
        span(class = "status-pill ok", "OMOP")
      else
        span(class = "status-pill bad", "NOT OMOP")
      lines <- c(lines, list(
        div(class = "sidebar-status-line", strong("Detection: "), omop_tag)
      ))
    }
    if (!is.null(ver)) {
      lines <- c(lines, list(
        div(class = "sidebar-status-line",
            strong("CDM version: "), ver)
      ))
    } else if (!is.null(det) && det$is_omop) {
      lines <- c(lines, list(
        div(class = "sidebar-status-line",
            strong("CDM version: "),
            span(class = "status-pill warn", "unknown"))
      ))
    }
    if (!is.null(val)) {
      n_wrong <- as.integer(val$summary$wrong_type %||% 0L)
      n_miss  <- as.integer(val$summary$missing_col %||% 0L)
      pill <- if (n_wrong == 0 && n_miss == 0)
        span(class = "status-pill ok", "clean")
      else
        span(class = "status-pill bad", sprintf("%d issues", n_wrong + n_miss))
      lines <- c(lines, list(
        div(class = "sidebar-status-line", strong("Validation: "), pill)
      ))
    }
    do.call(tagList, lines)
  })

  # ── Tab 1: Detect ──────────────────────────────────────────────────────
  output$detect_summary <- renderUI({
    sch <- input$schema_select
    if (is.null(sch) || !nzchar(sch)) {
      return(div(class = "alert alert-info",
                 "Pick a schema from the sidebar to begin."))
    }
    det <- detection_rv()
    if (is.null(det)) return(div("Loading..."))

    cdm_raw <- det$cdm_version_raw %||% "(not declared)"
    ver_norm <- cdm_version_rv()

    # Card content
    card <- div(class = "status-card",
      div(class = "label-row",
          span("Schema"), strong(sch)),
      div(class = "label-row",
          span("Total tables"),
          strong(format(det$n_total, big.mark = ","))),
      div(class = "label-row",
          span("CDM tables matched"),
          strong(sprintf("%d / %d", det$hit_count, length(OMOP_CDM_TABLES)))),
      div(class = "label-row",
          span("OMOP-shaped"),
          if (det$is_omop) span(class = "status-pill ok", "yes")
          else             span(class = "status-pill bad", "no")),
      div(class = "label-row",
          span("Declared CDM version"),
          tags$code(cdm_raw)),
      div(class = "label-row",
          span("Resolved version"),
          if (!is.null(ver_norm)) span(class = "status-pill info", ver_norm)
          else span(class = "status-pill warn", "unrecognised"))
    )
    card
  })

  output$detect_proceed_ui <- renderUI({
    det <- detection_rv()
    ver <- cdm_version_rv()
    if (is.null(det)) return(NULL)

    if (!det$is_omop) {
      return(div(class = "alert alert-danger",
        strong("This schema does not look like OMOP CDM."),
        " Fewer than 6 canonical CDM tables were matched. ",
        "The validator only operates on OMOP-shaped schemas."))
    }
    if (is.null(ver)) {
      return(tagList(
        div(class = "alert alert-warning",
          strong("Could not determine CDM version automatically."),
          " The ", tags$code("cdm_source.cdm_version"),
          " value was missing or unrecognised. Pick a version manually:"),
        radioButtons("manual_version", NULL,
          choices = c("v5.3" = "v5.3", "v5.4" = "v5.4"),
          selected = "v5.4", inline = TRUE),
        actionButton("apply_manual_version", "Use this version",
                     icon = icon("check"), class = "btn-primary")
      ))
    }
    div(class = "alert alert-success",
      strong("Ready to validate."),
      sprintf(" Schema %s detected as OMOP CDM %s. ", input$schema_select, ver),
      "Proceed to the Validate tab.")
  })

  observeEvent(input$apply_manual_version, {
    ver <- input$manual_version %||% "v5.4"
    cdm_version_rv(ver)
    spec_rv(if (ver == "v5.4") OMOP_CDM_V5_4 else OMOP_CDM_V5_3)
    showNotification(sprintf("Using CDM %s spec.", ver), type = "message")
  })

  output$detect_tables_dt <- DT::renderDT({
    sch <- input$schema_select
    req(sch, nzchar(sch))
    cols_df <- cols_df_rv()
    req(!is.null(cols_df))
    if (nrow(cols_df) == 0) return(NULL)

    # Aggregate to table-level: name, column count, in-CDM flag
    agg <- aggregate(column_name ~ table_name, data = cols_df, FUN = length)
    names(agg) <- c("table_name", "n_columns")
    agg$in_cdm_spec <- ifelse(agg$table_name %in% OMOP_CDM_TABLES, "yes", "no")
    agg <- agg[order(agg$in_cdm_spec == "no", agg$table_name), ]
    DT::datatable(agg, rownames = FALSE, filter = "none",
                  options = list(pageLength = 25, dom = "tip"))
  })

  # ── Tab 2: Validate ────────────────────────────────────────────────────
  output$validate_status_inline <- renderUI({
    val <- validation_rv()
    if (is.null(val)) return(span(style = "color: #777; font-size: 12px;",
                                  "Not yet run."))
    span(style = "color: #00a65a; font-size: 12px;",
         icon("check"), sprintf(" Last run validated %d expected tables.",
                                val$n_tables_expected))
  })

  observeEvent(input$run_validation, {
    sch <- input$schema_select
    if (is.null(sch) || !nzchar(sch)) {
      showNotification("Select a schema first.", type = "warning"); return()
    }
    spec <- spec_rv()
    if (is.null(spec)) {
      showNotification(
        "No CDM version resolved. Pick a version on the Detect tab first.",
        type = "warning"); return()
    }
    cols_df <- cols_df_rv()
    req(!is.null(cols_df))

    val <- tryCatch(
      validate_schema(sch, spec, cols_df),
      error = function(e) {
        showNotification(paste("Validation failed:", e$message), type = "error")
        NULL
      }
    )
    req(!is.null(val))
    validation_rv(val)
    sql_lines_rv(NULL)  # invalidate previous script
    execution_rv(NULL)

    n_wrong <- as.integer(val$summary$wrong_type %||% 0L)
    if (n_wrong == 0) {
      showNotification("Validation complete - no type mismatches found.",
                       type = "message")
    } else {
      showNotification(sprintf("Validation complete - %d type mismatches found.",
                               n_wrong), type = "warning")
    }
  })

  output$findings_summary_ui <- renderUI({
    val <- validation_rv()
    if (is.null(val)) return(NULL)
    s <- val$summary

    n_ok    <- as.integer(s$ok          %||% 0L)
    n_wrong <- as.integer(s$wrong_type  %||% 0L)
    n_mc    <- as.integer(s$missing_col %||% 0L)
    n_mt    <- as.integer(s$missing_tbl %||% 0L)
    n_xc    <- as.integer(s$extra_col   %||% 0L)

    div(class = "findings-summary",
      div(class = "stat ok",
        div(class = "num", format(n_ok, big.mark = ",")),
        div(class = "lbl", "OK")),
      div(class = "stat wrong",
        div(class = "num", format(n_wrong, big.mark = ",")),
        div(class = "lbl", "Wrong type")),
      div(class = "stat miss",
        div(class = "num", format(n_mc, big.mark = ",")),
        div(class = "lbl", "Missing col")),
      div(class = "stat miss",
        div(class = "num", format(n_mt, big.mark = ",")),
        div(class = "lbl", "Missing tbl")),
      div(class = "stat",
        div(class = "num", format(n_xc, big.mark = ",")),
        div(class = "lbl", "Extra col"))
    )
  })

  output$findings_dt <- DT::renderDT({
    val <- validation_rv()
    if (is.null(val)) return(NULL)
    df <- val$findings
    filt <- input$findings_filter %||% "all"
    if (filt != "all") df <- df[df$status == filt, , drop = FALSE]
    if (nrow(df) == 0) {
      df <- data.frame(message = "No rows match the current filter.",
                       stringsAsFactors = FALSE)
      return(DT::datatable(df, rownames = FALSE, filter = "none",
                           options = list(dom = "t")))
    }
    # Prettify column order
    df <- df[, c("table_name", "column_name", "status",
                 "expected_cat", "actual_cat", "actual_type"), drop = FALSE]
    DT::datatable(df, rownames = FALSE, filter = "none",
      options = list(pageLength = 25, dom = "tip",
                     order = list(list(0, "asc"), list(1, "asc"))),
      colnames = c("Table", "Column", "Status",
                   "Expected", "Actual category", "Actual type")) |>
      DT::formatStyle("status",
        backgroundColor = DT::styleEqual(
          c("ok", "wrong_type", "missing_col", "missing_tbl", "extra_col"),
          c("#d4edda", "#f8d7da", "#fff3cd", "#fff3cd", "#e2e3e5")),
        fontWeight = "600")
  })

  # ── Tab 3: Preview ─────────────────────────────────────────────────────
  # Generate SQL whenever validation results change.
  observe({
    val <- validation_rv()
    if (is.null(val)) { sql_lines_rv(NULL); return() }
    sch <- input$schema_select
    ver <- cdm_version_rv()
    req(sch, nzchar(sch))

    lines <- build_fix_script(sch, ver, val$findings)
    sql_lines_rv(lines)
  })

  output$preview_stats <- renderText({
    lines <- sql_lines_rv()
    if (is.null(lines)) return("Run validation first.")
    val <- validation_rv()
    n_wrong <- as.integer(val$summary$wrong_type %||% 0L)
    sprintf("%d ALTER statement%s, %d total lines",
            n_wrong, if (n_wrong == 1) "" else "s", length(lines))
  })

  output$preview_sql_ui <- renderUI({
    lines <- sql_lines_rv()
    if (is.null(lines))
      return(div(class = "alert alert-info",
                 "Run validation on the previous tab to generate a script."))

    # Apply minimal syntax highlighting for SQL keywords and comments.
    body <- vapply(lines, function(line) {
      esc <- htmltools::htmlEscape(line)
      if (grepl("^\\s*--", line)) {
        return(sprintf('<span class="sql-comment">%s</span>', esc))
      }
      esc <- gsub("\\b(BEGIN|COMMIT|ROLLBACK|ALTER TABLE|ALTER COLUMN|TYPE|USING|CASE|WHEN|THEN|ELSE|END)\\b",
                  '<span class="sql-keyword">\\1</span>', esc, perl = TRUE)
      esc
    }, character(1), USE.NAMES = FALSE)

    HTML(sprintf('<div class="sql-preview">%s</div>',
                 paste(body, collapse = "\n")))
  })

  output$download_sql <- downloadHandler(
    filename = function() {
      sch <- input$schema_select %||% "schema"
      sprintf("omop_fix_%s_%s.sql", sch, format(Sys.Date(), "%Y%m%d"))
    },
    content = function(file) {
      lines <- sql_lines_rv() %||% character(0)
      writeLines(lines, file)
      dl_dir <- ensure_downloads()
      sch <- input$schema_select %||% "schema"
      mirror <- file.path(dl_dir,
                          sprintf("omop_fix_%s_%s.sql", sch,
                                  format(Sys.Date(), "%Y%m%d")))
      writeLines(lines, mirror)
    }
  )

  # ── Tab 4: Execute ─────────────────────────────────────────────────────
  output$execute_status_ui <- renderUI({
    lines <- sql_lines_rv()
    val   <- validation_rv()
    if (is.null(lines) || is.null(val))
      return(div(class = "alert alert-warning",
                 "Generate a script first by running validation."))

    n_wrong <- as.integer(val$summary$wrong_type %||% 0L)
    if (n_wrong == 0)
      return(div(class = "alert alert-success",
                 strong("Nothing to execute."),
                 " Validation found no fixable type mismatches."))

    div(class = "alert alert-info",
        sprintf("Ready to execute %d ALTER statement%s in a single transaction.",
                n_wrong, if (n_wrong == 1) "" else "s"))
  })

  observeEvent(input$execute_btn, {
    lines <- sql_lines_rv()
    val   <- validation_rv()
    sch   <- input$schema_select
    if (is.null(lines) || is.null(val) || is.null(sch) || !nzchar(sch)) {
      showNotification("Generate a script first.", type = "warning"); return()
    }
    n_wrong <- as.integer(val$summary$wrong_type %||% 0L)
    if (n_wrong == 0) {
      showNotification("Nothing to execute.", type = "message"); return()
    }
    if (!conn_valid()) {
      showNotification("No database connection.", type = "error"); return()
    }

    showModal(modalDialog(
      title = tagList(icon("exclamation-triangle"), " Confirm execution"),
      tagList(
        p(sprintf("This will run %d ALTER TABLE statement%s against schema ",
                  n_wrong, if (n_wrong == 1) "" else "s"),
          tags$code(sch), "."),
        p("All statements run inside a transaction - any failure rolls ",
          "everything back. The schema will be unchanged unless every ",
          "statement succeeds."),
        p(strong("This cannot be undone automatically. Type the schema name to confirm:")),
        textInput("execute_confirm_text", NULL, value = "", width = "100%",
                  placeholder = sch)
      ),
      footer = tagList(
        modalButton("Cancel"),
        actionButton("execute_confirmed", "Execute now",
                     icon = icon("bolt"), class = "btn-danger")
      ),
      easyClose = FALSE, size = "m"
    ))
  })

  observeEvent(input$execute_confirmed, {
    sch <- input$schema_select
    if (is.null(input$execute_confirm_text) ||
        input$execute_confirm_text != sch) {
      showNotification("Schema name does not match - execution cancelled.",
                       type = "warning")
      return()
    }
    removeModal()

    lines <- sql_lines_rv()
    statements <- split_sql_statements(lines)

    log <- character(0)
    log <- c(log, sprintf("[%s] Starting execution against schema '%s'",
                          format(Sys.time(), "%H:%M:%S"), sch))
    log <- c(log, sprintf("[%s] %d statement(s) to run",
                          format(Sys.time(), "%H:%M:%S"), length(statements)))
    execution_rv(list(state = "running", log = log,
                      started = Sys.time(), finished = NULL))

    success <- TRUE
    err_msg <- NULL
    n_executed <- 0L
    progress <- shiny::Progress$new(session, min = 0, max = length(statements))
    on.exit(progress$close(), add = TRUE)
    progress$set(message = "Executing remediation script...", value = 0)

    for (i in seq_along(statements)) {
      stmt <- statements[i]
      progress$inc(1, detail = sprintf("Statement %d of %d", i, length(statements)))

      # First statement is BEGIN; last is COMMIT. Run them as-is.
      result <- tryCatch(
        DBI::dbExecute(DRE_CONN, stmt),
        error = function(e) {
          err_msg <<- e$message
          success <<- FALSE
          NULL
        }
      )
      if (!success) {
        log <- c(log,
          sprintf("[%s] FAIL on statement %d: %s",
                  format(Sys.time(), "%H:%M:%S"), i, err_msg),
          "  " %+% strtrim(gsub("\n", " ", stmt), 200))
        break
      }
      n_executed <- n_executed + 1L
      # Only log non-trivial statements
      if (!toupper(trimws(stmt)) %in% c("BEGIN", "COMMIT", "ROLLBACK")) {
        first_line <- strsplit(stmt, "\n", fixed = TRUE)[[1]][1]
        log <- c(log, sprintf("[%s] OK  : %s",
                              format(Sys.time(), "%H:%M:%S"),
                              trimws(first_line)))
      }
    }

    if (!success) {
      # Attempt rollback. The failed statement may already have aborted the
      # transaction; ROLLBACK is safe either way.
      rb <- tryCatch(DBI::dbExecute(DRE_CONN, "ROLLBACK"),
                     error = function(e) NULL)
      log <- c(log,
               sprintf("[%s] Transaction rolled back. No changes were committed.",
                       format(Sys.time(), "%H:%M:%S")))
      execution_rv(list(state = "failed", log = log,
                        started = isolate(execution_rv()$started),
                        finished = Sys.time(),
                        n_executed = n_executed,
                        error = err_msg))
      showNotification("Execution failed. Transaction rolled back.",
                       type = "error", duration = 10)
    } else {
      log <- c(log,
               sprintf("[%s] All %d statement(s) committed successfully.",
                       format(Sys.time(), "%H:%M:%S"), n_executed))
      execution_rv(list(state = "succeeded", log = log,
                        started = isolate(execution_rv()$started),
                        finished = Sys.time(),
                        n_executed = n_executed,
                        error = NULL))
      showNotification("Execution succeeded. Re-running validation...",
                       type = "message", duration = 6)

      # Auto re-run detection + validation against the post-fix schema.
      cols_df <- tryCatch(get_columns_for_schema(sch),
                          error = function(e) NULL)
      if (!is.null(cols_df)) {
        cols_df_rv(cols_df)
        spec <- spec_rv()
        if (!is.null(spec)) {
          new_val <- tryCatch(validate_schema(sch, spec, cols_df),
                              error = function(e) NULL)
          if (!is.null(new_val)) {
            validation_rv(new_val)
          }
        }
      }
    }
  })

  output$execution_log_ui <- renderUI({
    ex <- execution_rv()
    if (is.null(ex)) return(NULL)

    body <- vapply(ex$log, function(line) {
      esc <- htmltools::htmlEscape(line)
      if (grepl("FAIL|rolled back|error", line, ignore.case = TRUE)) {
        sprintf('<span class="err-line">%s</span>', esc)
      } else if (grepl("OK |committed|succeeded", line)) {
        sprintf('<span class="ok-line">%s</span>', esc)
      } else if (grepl("Starting|statement\\(s\\) to run", line)) {
        sprintf('<span class="head-line">%s</span>', esc)
      } else esc
    }, character(1), USE.NAMES = FALSE)

    tagList(
      h4("Execution log"),
      HTML(sprintf('<div class="exec-log">%s</div>',
                   paste(body, collapse = "\n")))
    )
  })

}

# Small string-concat helper used in the execution log only.
`%+%` <- function(a, b) paste0(a, b)


# ── 9. LAUNCH ─────────────────────────────────────────────────────────────────

shinyApp(ui, server)
