export class HttpError extends Error {
  constructor(
    public status: number,
    message: string,
    public extra: Record<string, unknown> = {},
  ) {
    super(message);
  }
}
export const bad = (m: string) => new HttpError(400, m);
export const unauthorized = (m = 'Please log in') => new HttpError(401, m);
export const forbidden = (m: string) => new HttpError(403, m);
export const notFound = (m: string) => new HttpError(404, m);
export const conflict = (m: string) => new HttpError(409, m);

export const uuid = () => crypto.randomUUID();
export const nowIso = () => new Date().toISOString();
export const isUuid = (s: unknown): s is string => typeof s === 'string' && /^[0-9a-f-]{36}$/i.test(s);
