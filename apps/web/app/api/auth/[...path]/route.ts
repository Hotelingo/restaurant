import { auth } from "@/lib/auth/server";
import { passwordPolicyError } from "@/lib/auth/password-policy";

const handlers = auth.handler();

export const GET = handlers.GET;

export const POST: typeof handlers.POST = async (request, context) => {
  const url = new URL(request.url);
  const marker = "/api/auth/";
  const endpoint = url.pathname.includes(marker)
    ? url.pathname.split(marker, 2)[1] ?? ""
    : "";

  if (request.headers.get("content-type")?.includes("application/json")) {
    const body = await request.clone().json().catch(() => null);
    const policyError = passwordPolicyError(endpoint, body);

    if (policyError) {
      return Response.json(
        { message: policyError, code: "PASSWORD_POLICY" },
        { status: 422 },
      );
    }
  }

  return handlers.POST(request, context);
};
