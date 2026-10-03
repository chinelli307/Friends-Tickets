import messages from "@/messages/es.json";
import { isLoginErrorKey } from "@/lib/auth/errors";
import { LoginForm } from "./login-form";

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>;
}) {
  const { error } = await searchParams;
  const candidate = error ?? null;
  const initialError = isLoginErrorKey(candidate) ? candidate : null;

  return (
    <main className="flex flex-1 items-center justify-center px-4">
      <div className="w-full max-w-sm">
        <h1 className="mb-6 text-3xl font-semibold">{messages.login.title}</h1>
        <LoginForm initialError={initialError} />
      </div>
    </main>
  );
}
