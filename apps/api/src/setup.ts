import { INestApplication, ValidationPipe } from '@nestjs/common';
import cookieParser from 'cookie-parser';
import express from 'express';
import helmet from 'helmet';
import { existsSync } from 'fs';
import { join, resolve } from 'path';
import { config } from './common/config';

/** Shared by main.ts and the tests so both run the same app. */
export function configureApp(app: INestApplication) {
  app.setGlobalPrefix('api/v1');
  app.use(
    helmet({
      contentSecurityPolicy: {
        directives: {
          defaultSrc: ["'self'"],
          // Next.js static pages use small inline scripts; Google sign-in loads from accounts.google.com.
          scriptSrc: ["'self'", "'unsafe-inline'", 'https://accounts.google.com/gsi/client'],
          styleSrc: ["'self'", "'unsafe-inline'", 'https://fonts.googleapis.com', 'https://accounts.google.com/gsi/style'],
          fontSrc: ["'self'", 'https://fonts.gstatic.com', 'data:'],
          imgSrc: ["'self'", 'data:', 'blob:', 'https:'],
          connectSrc: ["'self'", 'https://accounts.google.com/gsi/'],
          frameSrc: ['https://accounts.google.com/gsi/'],
          mediaSrc: ["'self'", 'blob:'],
          workerSrc: ["'self'", 'blob:'],
          objectSrc: ["'none'"],
          frameAncestors: ["'none'"],
        },
      },
      crossOriginOpenerPolicy: { policy: 'same-origin-allow-popups' },
    }),
  );
  app.use((_req: express.Request, res: express.Response, next: express.NextFunction) => {
    res.setHeader('Permissions-Policy', 'camera=(self), microphone=(), geolocation=()');
    next();
  });
  app.use(cookieParser());
  app.enableCors({ origin: config.adminOrigins, credentials: true });
  app.useGlobalPipes(new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true }));
  (app.getHttpAdapter().getInstance() as express.Express).set('trust proxy', 1);
  serveAdmin(app);
  return app;
}

/** Serves the static admin panel (apps/admin/out) from the same origin as the API. */
function serveAdmin(app: INestApplication) {
  const dir = resolve(process.env.ADMIN_DIST || join(__dirname, '..', '..', 'admin', 'out'));
  if (!existsSync(join(dir, 'index.html'))) return;
  const server = app.getHttpAdapter().getInstance() as express.Express;
  server.use(
    express.static(dir, {
      index: 'index.html',
      redirect: true,
      setHeaders: (res, path) => {
        if (path.includes(`${'/_next/static/'}`)) res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
        else res.setHeader('Cache-Control', 'no-cache');
      },
    }),
  );
  server.use((req: express.Request, res: express.Response, next: express.NextFunction) => {
    if (req.method !== 'GET' || req.path.startsWith('/api/')) return next();
    res.status(404).sendFile(join(dir, '404.html'));
  });
}
