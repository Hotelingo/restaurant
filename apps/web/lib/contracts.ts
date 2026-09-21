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
