import { NestFactory } from '@nestjs/core';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import { AppModule } from './app.module';
import { ensureBaseData } from './base-data';
import { PrismaService } from './common/prisma.service';
import { config } from './common/config';
import { configureApp } from './setup';

async function bootstrap() {
  // Fail fast in production if secrets are missing.
  void config.jwtSecret;
  void config.qrSecret;
  const app = configureApp(await NestFactory.create(AppModule));
  await ensureBaseData(app.get(PrismaService));
  const doc = SwaggerModule.createDocument(app, new DocumentBuilder().setTitle('GymMantra API').setVersion('1').addBearerAuth().build());
  SwaggerModule.setup('api/docs', app, doc);
  const port = Number(process.env.PORT || 4000);
  await app.listen(port, '0.0.0.0');
  console.log(`GymMantra API on :${port}`);
}
bootstrap();
