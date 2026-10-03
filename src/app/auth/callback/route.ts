import { NextResponse, type NextRequest } from "next/server";
import { isAuthPKCECodeVerifierMissingError } from "@supabase/supabase-js";
import {
  errorKeyFromSupabaseCode,
  type LoginErrorKey,
} from "@/lib/auth/errors";
import { safeNext } from "@/lib/auth/safe-next";
import { createClient } from "@/lib/supabase/server";

export async function GET(request: NextRequest) {
  const { searchParams, origin } = request.nextUrl;

  const toLogin = (error: LoginErrorKey) =>
    NextResponse.redirect(`${origin}/login?error=${error}`);

  // Supabase puede devolver el error en la query (p. ej. enlace caducado).
  if (searchParams.has("error") || searchParams.has("error_code")) {
    return toLogin(errorKeyFromSupabaseCode(searchParams.get("error_code")));
  }

  const code = searchParams.get("code");
  if (!code) return toLogin("missing_code");

  const supabase = await createClient();
  const { error } = await supabase.auth.exchangeCodeForSession(code);

  if (error) {
    return toLogin(
      isAuthPKCECodeVerifierMissingError(error)
        ? "other_browser"
        : "exchange_failed",
    );
  }

  const next = safeNext(searchParams.get("next"), origin);
  return NextResponse.redirect(`${origin}${next}`);
}
