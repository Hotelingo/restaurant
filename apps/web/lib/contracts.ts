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
