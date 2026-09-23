import { redirect } from "next/navigation";

// The Data Centre is outlet- and period-scoped: /app/outlets/{id}/data.
export default function LegacyDataCentre() {
  redirect("/app");
}
