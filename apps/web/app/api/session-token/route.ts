import { auth } from "@/lib/auth/server";

export const dynamic = "force-dynamic";

export async function GET() {
  const result = await auth.token();
  const token =
    result.data &&
    typeof result.data === "object" &&
    "token" in result.data
      ? (result.data as { token?: unknown }).token
      : null;

  if (typeof token !== "string" || token.split(".").length !== 3) {
    return Response.json(
      { token: null },
      {
        status: result.error?.status ?? 401,
        headers: { "Cache-Control": "no-store" },
      },
    );
  }

  return Response.json(
    { token },
    { headers: { "Cache-Control": "no-store" } },
  );
}
