import { redirect } from "next/navigation";
import messages from "@/messages/es.json";
import { createClient } from "@/lib/supabase/server";
import { signOut } from "./actions";

export default async function Home() {
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();

  if (!data?.claims) redirect("/login");

  return (
    <main className="flex flex-1 flex-col items-center justify-center gap-4">
      <h1 className="text-3xl font-semibold">{messages.home.placeholder}</h1>
      <p>
        {messages.home.signedInAs} {data.claims.email}
      </p>
      <form action={signOut}>
        <button type="submit" className="underline">
          {messages.home.signOut}
        </button>
      </form>
    </main>
  );
}
