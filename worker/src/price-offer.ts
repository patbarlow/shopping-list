export interface PriceOffer {
  name: string;
  price: number | null;
  size: number | null;
  unit: "mL" | "g" | "each" | null;
  question: string | null;
}
export function validateOffer(raw: unknown): PriceOffer | null {
  if (!raw || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  if (typeof o.name !== "string" || !o.name.trim() || o.name.length > 200) return null;
  const positive = (v: unknown) => typeof v === "number" && Number.isFinite(v) && v > 0 && v <= 1_000_000 ? v : null;
  const price = positive(o.price), size = positive(o.size);
  const unit = o.unit === "mL" || o.unit === "g" || o.unit === "each" ? o.unit : null;
  return { name: o.name.trim(), price, size, unit,
    question: typeof o.question === "string" ? o.question.slice(0, 300) :
      (!price || !size || !unit ? "What is the price and total pack size?" : null) };
}
