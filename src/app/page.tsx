import messages from "@/messages/es.json";

export default function Home() {
  return (
    <main className="flex flex-1 items-center justify-center">
      <h1 className="text-3xl font-semibold">{messages.home.placeholder}</h1>
    </main>
  );
}
