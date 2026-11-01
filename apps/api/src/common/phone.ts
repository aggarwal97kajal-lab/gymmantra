/** Normalises an Indian mobile number to +91XXXXXXXXXX, or returns null. */
export function normalizePhone(input: string | undefined | null): string | null {
  if (!input) return null;
  let d = String(input).replace(/[^\d]/g, '');
  if (d.length === 12 && d.startsWith('91')) d = d.slice(2);
  if (d.length === 11 && d.startsWith('0')) d = d.slice(1);
  if (!/^[6-9]\d{9}$/.test(d)) return null;
  return `+91${d}`;
}

export function normalizeEmail(input: string | undefined | null): string | null {
  if (!input) return null;
  const e = String(input).trim().toLowerCase();
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e) ? e : null;
}
