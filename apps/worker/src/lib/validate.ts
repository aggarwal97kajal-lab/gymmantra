import { bad } from './http';

// Tiny body validators that return clean values or throw a 400 with a readable message.
type B = Record<string, unknown>;

export function body(x: unknown): B {
  if (!x || typeof x !== 'object' || Array.isArray(x)) throw bad('Invalid request');
  return x as B;
}

export function str(b: B, k: string, o: { min?: number; max?: number; label?: string } = {}): string {
  const v = b[k];
  const label = o.label ?? k;
  if (typeof v !== 'string' || !v.trim()) throw bad(`Enter ${label}`);
  const t = v.trim();
  if (o.min && t.length < o.min) throw bad(`${label[0].toUpperCase()}${label.slice(1)} must be at least ${o.min} characters`);
  if (t.length > (o.max ?? 500)) throw bad(`${label[0].toUpperCase()}${label.slice(1)} is too long`);
  return t;
}
export function optStr(b: B, k: string, o: { max?: number } = {}): string | undefined {
  const v = b[k];
  if (v === undefined || v === null || v === '') return undefined;
  if (typeof v !== 'string') throw bad(`Invalid ${k}`);
  if (v.length > (o.max ?? 500)) throw bad(`${k} is too long`);
  return v.trim();
}
export function int(b: B, k: string, o: { min?: number; max?: number; label?: string } = {}): number {
  const v = b[k];
  if (typeof v !== 'number' || !Number.isInteger(v)) throw bad(`Enter a whole number for ${o.label ?? k}`);
  if (o.min !== undefined && v < o.min) throw bad(`${o.label ?? k} must be at least ${o.min}`);
  if (o.max !== undefined && v > o.max) throw bad(`${o.label ?? k} is too large`);
  return v;
}
export function optInt(b: B, k: string, o: { min?: number; max?: number; label?: string } = {}): number | undefined {
  return b[k] === undefined || b[k] === null ? undefined : int(b, k, o);
}
export function optBool(b: B, k: string): boolean | undefined {
  const v = b[k];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== 'boolean') throw bad(`Invalid ${k}`);
  return v;
}
export function oneOf<T extends string>(b: B, k: string, list: readonly T[], optional = false): T | undefined {
  const v = b[k];
  if ((v === undefined || v === null || v === '') && optional) return undefined;
  if (typeof v !== 'string' || !list.includes(v as T)) throw bad(`Invalid ${k}`);
  return v as T;
}
export function strList(b: B, k: string, max = 30): string[] | undefined {
  const v = b[k];
  if (v === undefined) return undefined;
  if (!Array.isArray(v) || v.length > max || v.some((x) => typeof x !== 'string' || x.length > 120)) throw bad(`Invalid ${k}`);
  return (v as string[]).map((s) => s.trim()).filter(Boolean);
}

/** The file really is the JPEG / PNG it says it is (checked from its first bytes). */
export function isImage(mime: string, b64: string) {
  let head: string;
  try {
    head = atob(b64.slice(0, 16));
  } catch {
    return false;
  }
  const c = (i: number) => head.charCodeAt(i);
  if (mime === 'image/jpeg') return c(0) === 0xff && c(1) === 0xd8 && c(2) === 0xff;
  if (mime === 'image/png') return c(0) === 0x89 && c(1) === 0x50 && c(2) === 0x4e && c(3) === 0x47;
  return false;
}
