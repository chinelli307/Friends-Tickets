"use client";

import { useState, useSyncExternalStore } from "react";
import messages from "@/messages/es.json";
import {
  errorKeyFromSupabaseCode,
  type LoginErrorKey,
} from "@/lib/auth/errors";
import { createClient } from "@/lib/supabase/client";

type Status = "idle" | "sending" | "sent";

function subscribeToHash(callback: () => void) {
  window.addEventListener("hashchange", callback);
  return () => window.removeEventListener("hashchange", callback);
}

// Supabase puede devolver el error en el fragmento (#error_code=...).
// Solo se traduce el código; error_description nunca se muestra.
function readHashError(): LoginErrorKey | null {
  const params = new URLSearchParams(window.location.hash.slice(1));
  if (!params.has("error") && !params.has("error_code")) return null;
  return errorKeyFromSupabaseCode(params.get("error_code"));
}

export function LoginForm({
  initialError,
}: {
  initialError: LoginErrorKey | null;
}) {
  const [email, setEmail] = useState("");
  const [status, setStatus] = useState<Status>("idle");
  const [submitError, setSubmitError] = useState<LoginErrorKey | null>(null);
  const [staleCleared, setStaleCleared] = useState(false);
  const hashError = useSyncExternalStore(
    subscribeToHash,
    readHashError,
    () => null,
  );

  const error =
    submitError ?? (staleCleared ? null : (initialError ?? hashError));

  async function onSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setStatus("sending");
    setSubmitError(null);
    setStaleCleared(true);
    history.replaceState(null, "", window.location.pathname);

    const { error } = await createClient().auth.signInWithOtp({
      email,
      options: { emailRedirectTo: `${window.location.origin}/auth/callback` },
    });

    if (error) {
      setSubmitError(error.status === 429 ? "rate_limited" : "send_failed");
      setStatus("idle");
      return;
    }
    setStatus("sent");
  }

  if (status === "sent") {
    return (
      <div role="status">
        <h2 className="text-xl font-semibold">{messages.login.sentTitle}</h2>
        <p className="mt-2">{messages.login.sentBody}</p>
        <button
          type="button"
          className="mt-4 underline"
          onClick={() => setStatus("idle")}
        >
          {messages.login.sentAgain}
        </button>
      </div>
    );
  }

  const sending = status === "sending";

  return (
    <form onSubmit={onSubmit} className="flex flex-col gap-3">
      <label htmlFor="email" className="text-sm font-medium">
        {messages.login.emailLabel}
      </label>
      <input
        id="email"
        type="email"
        required
        autoComplete="email"
        value={email}
        onChange={(e) => setEmail(e.target.value)}
        placeholder={messages.login.emailPlaceholder}
        disabled={sending}
        className="rounded border border-zinc-300 px-3 py-2 dark:border-zinc-700 dark:bg-transparent"
      />
      {error && (
        <p role="alert" className="text-sm text-red-600">
          {messages.login.errors[error]}
        </p>
      )}
      <button
        type="submit"
        disabled={sending}
        className="rounded bg-foreground px-4 py-2 text-background disabled:opacity-60"
      >
        {sending
          ? messages.login.sending
          : error
            ? messages.login.retry
            : messages.login.submit}
      </button>
    </form>
  );
}
