import { randomUUID } from 'node:crypto';
import fp from 'fastify-plugin';
import type { FastifyPluginAsync } from 'fastify';
import { eq } from 'drizzle-orm';
import { items } from '../persistence/schema';

interface ItemBody {
  displayName: string;
}

interface ItemParams {
  id: string;
}

// Sample scaffold CRUD routes for the items table — the persistence round trip a
// black-box test can drive. The base path is the platform standard (S2): versioned,
// name-derived, kebab-case, naive plural. Rename alongside src/persistence/schema.ts
// when you add your real model. Writes generate ids in JS and read back after the
// write so the routes stay dialect-portable (MySQL has no RETURNING clause).
const base = '/api/v1/{{ entity-name }}s';

const itemRoutes: FastifyPluginAsync = async (fastify) => {
  fastify.post<{ Body: ItemBody }>(base, async (request, reply) => {
    const id = randomUUID();
    await fastify.db.insert(items).values({ id, displayName: request.body.displayName });
    const [item] = await fastify.db.select().from(items).where(eq(items.id, id));
    return reply.code(201).send(item);
  });

  fastify.get(base, async () =>
    fastify.db.select().from(items).orderBy(items.createdAt));

  fastify.get<{ Params: ItemParams }>(`${base}/:id`, async (request, reply) => {
    const [item] = await fastify.db.select().from(items).where(eq(items.id, request.params.id));
    if (!item) return reply.code(404).send({ message: 'Not Found' });
    return item;
  });

  fastify.put<{ Body: ItemBody; Params: ItemParams }>(`${base}/:id`, async (request, reply) => {
    const { id } = request.params;
    const [existing] = await fastify.db.select().from(items).where(eq(items.id, id));
    if (!existing) return reply.code(404).send({ message: 'Not Found' });
    await fastify.db.update(items).set({ displayName: request.body.displayName }).where(eq(items.id, id));
    const [item] = await fastify.db.select().from(items).where(eq(items.id, id));
    return item;
  });

  fastify.delete<{ Params: ItemParams }>(`${base}/:id`, async (request, reply) => {
    const { id } = request.params;
    const [existing] = await fastify.db.select().from(items).where(eq(items.id, id));
    if (!existing) return reply.code(404).send({ message: 'Not Found' });
    await fastify.db.delete(items).where(eq(items.id, id));
    return reply.code(204).send();
  });
};

export default fp(itemRoutes, { name: 'item-routes', dependencies: ['persistence'] });
