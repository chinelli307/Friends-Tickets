/**
 * Devuelve una ruta relativa propia a partir del parámetro `next`.
 * Cualquier valor que no sea una ruta del mismo origen cae en "/".
 */
export function safeNext(next: string | null, origin: string): string {
  if (!next || !next.startsWith("/")) return "/";

  try {
    const url = new URL(next, origin);
    if (url.origin !== origin) return "/";
    const result = `${url.pathname}${url.search}${url.hash}`;
    if (result.startsWith("//")) return "/";
    return result;
  } catch {
    return "/";
  }
}
