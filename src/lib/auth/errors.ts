export const LOGIN_ERROR_KEYS = [
  "send_failed",
  "rate_limited",
  "link_expired",
  "link_invalid",
  "missing_code",
  "other_browser",
  "exchange_failed",
  "generic",
] as const;

export type LoginErrorKey = (typeof LOGIN_ERROR_KEYS)[number];

export function isLoginErrorKey(value: string | null): value is LoginErrorKey {
  return LOGIN_ERROR_KEYS.some((key) => key === value);
}

// Solo códigos de error conocidos de Supabase. Los demás caen en "generic";
// nunca se muestra error_description.
const FROM_SUPABASE_CODE: Record<string, LoginErrorKey> = {
  otp_expired: "link_expired",
  access_denied: "link_invalid",
};

export function errorKeyFromSupabaseCode(code: string | null): LoginErrorKey {
  if (code && Object.hasOwn(FROM_SUPABASE_CODE, code)) {
    return FROM_SUPABASE_CODE[code];
  }
  return "generic";
}
