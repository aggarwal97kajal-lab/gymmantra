function req(name: string, devDefault?: string): string {
  const v = process.env[name];
  if (v && v.length) return v;
  if (process.env.NODE_ENV !== 'production' && devDefault !== undefined) return devDefault;
  throw new Error(`Missing required environment variable ${name}`);
}

export const config = {
  get jwtSecret() {
    return req('JWT_SECRET', 'dev-only-jwt-secret');
  },
  get qrSecret() {
    return req('QR_SECRET', 'dev-only-qr-secret');
  },
  get googleClientIds(): string[] {
    return (process.env.GOOGLE_CLIENT_IDS || '').split(',').map((s) => s.trim()).filter(Boolean);
  },
  get superAdminEmail() {
    return (process.env.SUPER_ADMIN_EMAIL || '').trim().toLowerCase();
  },
  get adminOrigins(): string[] {
    return (process.env.ADMIN_ORIGIN || 'http://localhost:3001').split(',').map((s) => s.trim());
  },
  get isProd() {
    return process.env.NODE_ENV === 'production';
  },
  /** Login lockout: wrong passwords allowed before the account is locked. */
  maxLoginAttempts: 3,
  lockMinutes: 15,
  sessionDays: 30,
};
