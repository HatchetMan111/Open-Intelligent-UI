// Open Intelligent UI (Proxmox-Patch): Modelliste für das Dropdown.
// GET /api/models -> { defaultModel, models: [{id, label}], live: boolean }
// Versucht die Live-Liste von OpenRouter, fällt auf die kuratierte
// Liste (patches/available-models.json) zurück. Schreibt niemals Keys raus.
import { readFile } from "node:fs/promises";
import { join } from "node:path";

type ModelEntry = { id: string; label: string };

async function curated(): Promise<ModelEntry[]> {
  try {
    const raw = await readFile(
      join(process.cwd(), "patches", "available-models.json"),
      "utf8",
    );
    const parsed: unknown = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      return (parsed as ModelEntry[]).filter(
        (m) => m && typeof m.id === "string" && typeof m.label === "string",
      );
    }
  } catch {
    // ignore – Fallback unten
  }
  return [{ id: "openai/gpt-6.1-sol", label: "GPT-6.1 Sol (Standard)" }];
}

export async function GET() {
  const fallback = await curated();
  const defaultModel =
    process.env.LLM_MODEL || process.env.THESYS_MODEL || fallback[0]?.id || "";
  const baseURL = process.env.LLM_BASE_URL || "";
  const apiKey = process.env.LLM_API_KEY || "";

  // Nur bei OpenRouter-Betrieb live abfragen (kein Key -> kein Abfluss).
  if (baseURL.includes("openrouter.ai") && apiKey) {
    try {
      const res = await fetch(`${baseURL.replace(/\/$/, "")}/models`, {
        headers: { Authorization: `Bearer ${apiKey}` },
      });
      if (res.ok) {
        const data = (await res.json()) as {
          data?: Array<{ id?: string; name?: string }>;
        };
        const live: ModelEntry[] = (data.data || [])
          .filter((m) => typeof m.id === "string")
          .map((m) => ({ id: m.id as string, label: m.name || (m.id as string) }))
          .slice(0, 200);
        if (live.length) {
          return Response.json({ defaultModel, models: live, live: true });
        }
      }
    } catch {
      // ignore – Fallback
    }
  }
  return Response.json({ defaultModel, models: fallback, live: false });
}
