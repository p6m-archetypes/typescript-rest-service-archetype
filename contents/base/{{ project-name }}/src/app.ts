import Fastify, { FastifyInstance } from 'fastify';
import { settings } from './settings';
{% if has_s3 %}
import { initS3 } from './resources/storage-s3';
{% endif %}
{% if has_azure_blob %}
import { initAzureBlob } from './resources/storage-azure';
{% endif %}

export interface BuildOptions {
  testing?: boolean;
}

export async function buildApp(opts: BuildOptions = {}): Promise<FastifyInstance> {
  const app = Fastify({
    logger: { level: settings.logLevel },
  });

  // Service routes
  app.get('/api/v1/ping', async () => ({ status: 'ok' }));
{% if has_s3 %}
  initS3();
{% endif %}
{% if has_azure_blob %}
  initAzureBlob();
{% endif %}
{% if persistence ~= 'None' %}
  if (!opts.testing) {
    const { default: persistencePlugin } = await import('./plugins/persistence');
    await app.register(persistencePlugin);
  }
{% endif %}{% if cache ~= 'None' %}
  if (!opts.testing) {
    const { default: cachePlugin } = await import('./plugins/cache');
    await app.register(cachePlugin);
  }
{% endif %}{% if messaging ~= 'None' %}
  if (!opts.testing) {
    const { default: messagingPlugin } = await import('./plugins/messaging');
    await app.register(messagingPlugin);
  }
{% endif %}
  return app;
}
