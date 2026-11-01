/** @type {import('next').NextConfig} */
const API_URL = process.env.API_URL || 'http://localhost:4000';
const dev = process.env.NODE_ENV === 'development';

// The admin panel is a static site (out/) served by the API on the same
// origin, so the session cookie stays first-party and httpOnly. In local
// development, Next forwards /api to the API instead.
module.exports = {
  output: dev ? undefined : 'export',
  trailingSlash: true,
  reactStrictMode: true,
  poweredByHeader: false,
  images: { unoptimized: true },
  ...(dev ? { rewrites: async () => [{ source: '/api/:path*', destination: `${API_URL}/api/:path*` }] } : {}),
};
