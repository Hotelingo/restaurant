export type OutletContext = {
  id: string;
  name: string;
  code: string | null;
  currency_code: string;
  timezone: string;
  roles: string[];
};

export type OrganisationContext = {
  id: string;
  name: string;
  slug: string;
  roles: string[];
  outlets: OutletContext[];
};

export type AuthContextResponse = {
  user_id: string;
  organisations: OrganisationContext[];
};

export type BootstrapRequest = {
  organisation_name: string;
  organisation_slug: string;
  outlet_name: string;
  outlet_code: string | null;
  currency_code: string;
  timezone: string;
  fiscal_year_start_month: number;
};

export type BootstrapResponse = {
  organisation_id: string;
  outlet_id: string;
  role: "admin";
};

export type ContextVersionResponse = {
  context_id: string;
  version_no: number;
};

export type ReportingPeriodResponse = {
  period_id: string;
};

export type SetupSummaryResponse = {
  organisation_id: string;
  organisation_name: string;
  outlet_id: string;
  outlet_name: string;
  outlet_code: string | null;
  currency_code: string;
  timezone: string;
  latest_context_version: number | null;
  periods: {
    id: string;
    label: string;
    period_start: string;
    period_end: string;
    close_status: string;
  }[];
};


export type AdditionalOutletResponse = {
  outlet_id: string;
};

export type MaterialityVersion = {
  id: string;
  scope_type: "general" | "food" | "beverage" | "labour" | "other_cost" | "menu";
  absolute_threshold: string | null;
  percent_threshold: string | null;
  source_kind: string;
  proposal_basis: Record<string, unknown>;
  recurrence_rule: Record<string, unknown>;
  risk_override_enabled: boolean;
  effective_from: string;
  effective_to: string | null;
  approved_at: string | null;
};

export type OutletControlsResponse = {
  organisation_id: string;
  outlet_id: string;
  outlet_name: string;
  currency_code: string;
  timezone: string;
  fiscal_year_start_month: number;
  settings: Record<string, unknown>;
  materiality: MaterialityVersion[];
};

export type AuditLogResponse = {
  organisation_id: string;
  events: {
    id: number;
    actor_user_id: string | null;
    actor_name: string | null;
    actor_email: string | null;
    outlet_id: string | null;
    action_code: string;
    object_type: string;
    object_id: string | null;
    correlation_id: string | null;
    occurred_at: string;
  }[];
};


export type InvitationCreateResponse = {
  invitation_id: string;
  token: string;
  accept_path: string;
  expires_at: string;
};

export type InvitationPreviewResponse = {
  invitation_id: string;
  organisation_name: string;
  role: string;
  scope_mode: string;
  outlet_names: string[];
  inviter_name: string | null;
  expires_at: string;
  status: string;
};

export type MemberRow = {
  membership_id: string;
  user_id: string;
  display_name: string | null;
  email: string | null;
  role: string;
  scope_mode: string;
  outlet_ids: string[];
  outlet_names: string[];
  active: boolean;
};

export type InvitationRow = {
  invitation_id: string;
  email: string;
  role: string;
  scope_mode: string;
  outlet_ids: string[];
  outlet_names: string[];
  status: string;
  expires_at: string;
  created_at: string;
};

export type MembersResponse = {
  organisation_id: string;
  organisation_name: string;
  outlets: {
    id: string;
    name: string;
    code: string | null;
  }[];
  members: MemberRow[];
  invitations: InvitationRow[];
};


export type CalcInputTrace = {
  input_role: string;
  scenario: string;
  batch_id: string;
  profile_version_id: string;
  canonical_commit_hash: string;
  source_file_id: string;
  original_filename: string;
  source_sha256: string;
};

export type CalcRunSummary = {
  id: string;
  outlet_id: string;
  period_id: string;
  engine_version: string;
  status: string;
  comparator_scenario: string | null;
  result_hash: string | null;
  started_at: string | null;
  completed_at: string | null;
  settings_snapshot: Record<string, unknown>;
  inputs: CalcInputTrace[];
};

export type CalcResultRead = {
  id: string;
  calc_id: string;
  grain_type: string;
  grain_key: Record<string, unknown>;
  value_numeric: string | null;
  value_text: string | null;
  unit: string;
  currency_code: string | null;
  calculation_status: string;
  evidence_status: string;
  explanation_code: string | null;
  result_metadata: Record<string, unknown>;
  input_refs: string[];
  raw_delta: string | null;
  profit_effect: string | null;
};

export type PLLineRead = {
  line_code: string;
  label: string;
  display_order: number;
  is_calculated: boolean;
  actual: CalcResultRead | null;
  comparator: CalcResultRead | null;
  variance: CalcResultRead | null;
};

export type PLAnalysisResponse = {
  outlet_id: string;
  outlet_name: string;
  currency_code: string;
  period: {
    id: string;
    label: string;
    period_start: string;
    period_end: string;
  };
  run: CalcRunSummary;
  lines: PLLineRead[];
  first_material_movement: CalcResultRead | null;
};

export type ReconciliationLineRead = {
  line_code: string;
  label: string;
  display_order: number;
  statement_accounts: string[];
  management_amount: string | null;
  accounting_amount: string;
  difference: string | null;
  status: string;
  calc_result_id: string | null;
  financial_fact_ids: string[];
  explanation_code: string | null;
};

export type ReconciliationResponse = {
  outlet_id: string;
  outlet_name: string;
  currency_code: string;
  period: {
    id: string;
    label: string;
    period_start: string;
    period_end: string;
  };
  run_id: string;
  source_batch_id: string;
  source_file_id: string;
  original_filename: string;
  source_sha256: string;
  status: string;
  scope: string;
  lines: ReconciliationLineRead[];
  cross_module_status: string;
  cross_module_note: string;
};

// ---------------------------------------------------------------- Data Centre

export type TemplateCode = "T1" | "T1B" | "T2" | "T3" | "T4A" | "T5" | "T6" | "T7";
export type Scenario = "actual" | "budget" | "forecast" | "prior_year";

export type ImportBatchSummary = {
  batch_id: string;
  source_file_id: string;
  template_code: TemplateCode;
  scenario: Scenario;
  status: string;
  period_id: string | null;
  original_filename: string;
  size_bytes: number | null;
  row_count: number | null;
  profile_match_tier: string | null;
  uploaded_at: string;
  committed_at: string | null;
};

export type ImportBatchListResponse = { outlet_id: string; batches: ImportBatchSummary[] };

export type ImportUploadResponse = {
  source_file_id: string;
  batch_id: string;
  status: string;
  detected_file_type: string;
  content_type: string;
  size_bytes: number;
  row_count: number;
  sha256: string;
};

export type ImportParseResponse = {
  batch_id: string;
  status: string;
  staging_row_count: number;
  parse_error_count: number;
  fingerprint: string;
  profile_match_tier: string;
  profile_match_message: string;
  profile_version_id: string | null;
  candidate_profile_version_id: string | null;
};

export type ImportStatusResponse = {
  batch_id: string;
  source_file_id: string;
  template_code: TemplateCode;
  status: string;
  period_id: string | null;
  scenario: Scenario;
  staging_row_count: number;
  parse_error_count: number;
  unresolved_block_count: number;
  warning_count: number;
  fingerprint: string | null;
  profile_match_tier: string | null;
  profile_match_message: string | null;
  profile_version_id: string | null;
  candidate_profile_version_id: string | null;
  canonical_commit_hash: string | null;
};

export type ImportExceptionItem = {
  kind: string;
  identity: string;
  source_row_numbers: number[];
  source_account_code?: string | null;
  source_account_name?: string | null;
  source_value?: string | null;
  suggested_management_line?: string | null;
};

export type ImportExceptionsResponse = {
  batch_id: string;
  profile_version_id: string | null;
  candidate_profile_version_id: string | null;
  exceptions: ImportExceptionItem[];
};

export type MappingConfirmRequest = {
  source_label?: string | null;
  base_profile_version_id?: string | null;
  account_mappings?: { source_account_code?: string | null; source_account_name: string; ladder_line_code: string }[];
  management_line_mappings?: { source_value: string; ladder_line_code: string }[];
  item_mappings?: { source_item_code?: string | null; source_item_name?: string | null; canonical_item_key: string }[];
  product_group_mappings?: { source_value: string; canonical_value: "food" | "beverage" }[];
  labour_activity_basis_mappings?: { source_role_group: string; activity_basis: string }[];
};

export type MappingConfirmResponse = {
  batch_id: string;
  profile_version_id: string;
  version_no: number;
  status: string;
  reused: boolean;
};

export type ImportValidateResponse = {
  batch_id: string;
  status: string;
  unresolved_block_count: number;
  warning_count: number;
  validation_count: number;
};

export type ImportCommitResponse = {
  batch_id: string;
  status: string;
  fact_count: number;
  canonical_commit_hash: string;
  reused: boolean;
};

export type CalculationModule = "pl" | "food_cost" | "revenue" | "labour_other";

export type CalculationRequestResponse = {
  request_id: string;
  status: string;
  reused: boolean;
  source_batch_id: string;
};

export type CalculationStatus = {
  request_id: string;
  reason: string;
  status: string;
  attempts: number;
  created_at: string;
  started_at: string | null;
  completed_at: string | null;
  completed_run_id: string | null;
  last_error: string | null;
};

export type CalculationStatusResponse = { period_id: string; requests: CalculationStatus[] };

// ---------------------------------------------------------------- Review loop

export type EvidenceStatus =
  | "validated" | "supported" | "partly_supported" | "evidence_required" | "not_reconciled" | "not_applicable";

export type ContextVersionSummary = {
  id: string; version_no: number; service_style: string | null;
  effective_from: string; effective_to: string | null; applies_to_period: boolean;
};
export type ContextVersionListResponse = { outlet_id: string; versions: ContextVersionSummary[] };

export type ReviewRead = {
  id: string; outlet_id: string; period_id: string; status: string;
  comparator_scenario: string | null; context_version_id: string | null;
  materiality_snapshot: Record<string, unknown>; active_calc_run_id: string | null;
  review_leader_id: string; started_at: string; frame_confirmed_at: string | null;
  closed_at: string | null; created_at: string; updated_at: string;
};
export type ReviewListResponse = { reviews: ReviewRead[] };
export type ReviewMutationResponse = { review: ReviewRead; reused: boolean };

export type ShortlistGuidance = "below_expected" | "expected_range" | "six_with_reason" | "above_expected_warning";
export type ReviewIssueRead = {
  id: string; review_id: string; source_calc_run_id: string; source_calc_result_id: string;
  title: string; movement_amount: string; movement_rate: string | null; ladder_code: string;
  module: string; materiality_reason: string; materiality_rules: string[]; shortlist_order: number;
  selection_reason: string | null; evidence_status: string; issue_status: string;
  created_by: string; created_at: string; updated_at: string;
};
export type ReviewIssueListResponse = { issues: ReviewIssueRead[]; shortlist_count: number; shortlist_guidance: ShortlistGuidance };
export type ReviewIssueMutationResponse = {
  issue: ReviewIssueRead; shortlist_count: number; shortlist_guidance: ShortlistGuidance; reused: boolean;
};

export type DiagnosisRead = {
  id: string; review_issue_id: string; version_no: number; diagnosis_state: "supported" | "hypothesis" | "unknown";
  driver_code: string | null; driver_name: string | null; supported_summary: string | null;
  hypothesis_summary: string | null; unknowns: string | null; evidence_status: EvidenceStatus;
  diagnostic_status: string; created_at: string;
};
export type DriverEvidenceRead = {
  id: string; driver_code: string; driver_name: string; evidence_source_type: string; evidence_source_id: string;
  evidence_status: EvidenceStatus; quantified_impact: string | null; reconciliation_impact: string; note: string | null;
  created_at: string;
};
export type EvidenceRequestRead = {
  id: string; review_issue_id: string; requested_dataset: string; reason: string; minimum_fields: string[];
  owner: string; due_date: string; status: string; fulfilled_batch_id: string | null; created_at: string;
};
export type IssueEvidenceWorkspaceResponse = {
  issue_id: string; issue_title: string; issue_evidence_status: string;
  latest_diagnosis: DiagnosisRead | null; diagnosis_history: DiagnosisRead[];
  driver_evidence: DriverEvidenceRead[]; evidence_requests: EvidenceRequestRead[];
};

export type Disposition = "ACT" | "MONITOR" | "INVESTIGATE" | "ESCALATE" | "CLOSE";
export type DecisionRead = {
  id: string; review_issue_id: string; version_no: number; disposition: Disposition; decision_text: string;
  owner: string | null; lever: string | null; guardrail: string | null; verification_metric: string | null;
  target_trigger: string | null; due_date: string | null; cadence: string | null; evidence_request_id: string | null;
  decision_required: string | null; consequence_of_waiting: string | null; forecast_treatment: string | null;
  closure_evidence: string | null; decided_by: string; decided_at: string;
};
export type IssueDecisionWorkspaceResponse = {
  issue_id: string; issue_title: string; issue_evidence_status: string;
  active_decision: DecisionRead | null; decision_history: DecisionRead[];
};
export type DecisionCreateRequest = Partial<Omit<DecisionRead, "id" | "review_issue_id" | "version_no" | "decided_by" | "decided_at">> & {
  disposition: Disposition; decision_text: string;
};

export type ActionStatus = "OPEN_ON_TRACK" | "CLOSED" | "OVERDUE_NOT_COMPLETED" | "REPEATED_ISSUE" | "REOPENED";
export type ActionRead = {
  id: string; review_id: string; review_issue_id: string; decision_id: string; owner: string;
  lever: string | null; guardrail: string | null; metric: string | null; target_trigger: string | null;
  due_date: string | null; cadence: string | null; forecast_effect: string | null; status: ActionStatus;
  status_tag: string | null; closure_evidence: string | null; created_at: string; updated_at: string;
};
export type ActionListResponse = { actions: ActionRead[] };
export type ActionMutationResponse = { action: ActionRead; reused: boolean };

export type PackStatus = "draft" | "in_review" | "changes_requested" | "signed" | "superseded";
export type PackVersionRead = {
  id: string; review_id: string; version_no: number; calc_run_id: string; status: PackStatus;
  supersedes_pack_version_id: string | null; reconciliation_disclosure: string | null; generated_at: string;
  artifact_path: string | null; artifact_sha256: string | null; renderer_version: string | null;
  template_version: string | null; created_at: string; updated_at: string;
};
export type ClaimCheckRead = {
  passed: boolean; number_match: boolean; citation_present: boolean; banned_wording: boolean;
  unmatched_numbers: unknown[]; banned_terms: string[]; status_echo: string; direction: string; scope: string;
};
export type ClaimCitationRead = {
  id: string; calc_result_id: string; calc_id: string; value_numeric: string | null; value_text: string | null;
  unit: string; currency_code: string | null; calculation_status: string; evidence_status: string; citation_role: string;
};
export type PackClaimRead = {
  id: string; pack_version_id: string; section_code: string; claim_text: string;
  claim_status: "draft" | "edited" | "accepted" | "rejected"; evidence_status: EvidenceStatus;
  citations?: ClaimCitationRead[]; check?: ClaimCheckRead | null; created_at: string;
};
export type PackReadResponse = { pack: PackVersionRead; claims: PackClaimRead[] };
export type PackMutationResponse = { pack: PackVersionRead; reused: boolean };
export type PackClaimMutationResponse = { claim: PackClaimRead; reused: boolean };
export type PackClaimReviewResponse = { claim: PackClaimRead; check: ClaimCheckRead; reused: boolean };
export type PackArtifactRenderResponse = {
  pack: PackVersionRead; artifact_sha256: string; artifact_source_sha256: string; content_type: string; reused: boolean;
};
export type PackArtifactUrlResponse = { url: string; expires_in_seconds: number; artifact_sha256: string };
export type PackSubmitResponse = { pack_version_id: string; status: string; reused: boolean };

export type ReviewGateOutcome = { code: string; passed: boolean; message: string; remediation: string; subject_ids?: string[] };
export type ReviewGateResponse = {
  review_id: string; pack_version_id: string; passed: boolean; outcomes: ReviewGateOutcome[]; failures: ReviewGateOutcome[];
};
export type SignoffRead = {
  id: string; pack_version_id: string; reviewer_name: string; reviewer_role: string;
  decision: "signed" | "changes_requested"; caveat: string | null; created_at: string;
};
export type PackSignoffResponse = { signoff: SignoffRead; pack_status: string; reused: boolean };
export type PackHistoryVersion = {
  id: string; version_no: number; calc_run_id: string; status: string; generated_at: string;
  artifact_sha256: string | null; created_at: string; signoffs?: SignoffRead[];
};
export type ReviewPackHistoryResponse = { review_id: string; versions: PackHistoryVersion[] };
export type ReviewComment = {
  id: string; review_id: string; parent_comment_id: string | null; body: string; author_user_id: string;
  author_role: string; resolution_status: "open" | "resolved"; resolution_note: string | null; created_at: string;
};
export type CalcResultsResponse = { run_id: string; results: CalcResultRead[] };

// ── Mappings page (api/app/routes/mappings.py) ────────────────────────────

export type MappingProfileSummary = {
  source_profile_id: string;
  template_code: string;
  source_label: string;
  active_version_id: string | null;
  active_version_no: number | null;
  active_approved_at: string | null;
  version_count: number;
  account_count: number;
  value_count: number;
  item_count: number;
};

export type MappingProfileListResponse = {
  outlet_id: string;
  can_edit: boolean;
  profiles: MappingProfileSummary[];
};

export type MappingValueField = "management_line" | "product_group" | "labour_activity_basis";

export type MappingProfileDetailResponse = {
  source_profile_id: string;
  outlet_id: string;
  template_code: string;
  source_label: string;
  active_version_id: string | null;
  version_id: string;
  version_no: number;
  approved_at: string | null;
  supersedes_version_id: string | null;
  is_active: boolean;
  can_edit: boolean;
  versions: { id: string; version_no: number; approved_at: string | null; is_active: boolean }[];
  accounts: {
    source_identity_key: string;
    source_account_code: string | null;
    source_account_name: string;
    ladder_line_code: string;
    mapping_basis: string;
  }[];
  values: { field_name: string; source_value: string; canonical_value: string }[];
  items: { source_item_code: string | null; source_item_name: string; canonical_item_key: string }[];
  columns: { source_column: string; canonical_field: string }[];
};

export type MappingRevisionRequest = {
  account_changes: { source_identity_key: string; ladder_line_code: string }[];
  value_changes: { field_name: MappingValueField; source_value: string; canonical_value: string }[];
};

export type MappingRevisionResponse = {
  source_profile_id: string;
  profile_version_id: string;
  version_no: number;
  reused: boolean;
};
