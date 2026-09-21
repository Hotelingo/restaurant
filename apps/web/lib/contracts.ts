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
