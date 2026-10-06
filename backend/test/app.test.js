import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import request from 'supertest';
import { createApp } from '../src/app.js';

// In-memory stand-in for the Postgres data layer.
function fakeDb() {
  let nextId = 1;
  const items = [];
  return {
    healthy: true,
    async ping() {
      if (!this.healthy) throw new Error('db down');
    },
    async listItems() {
      return [...items].reverse();
    },
    async createItem(name) {
      const item = { id: nextId++, name, created_at: new Date().toISOString() };
      items.push(item);
      return item;
    },
    async deleteItem(id) {
      const i = items.findIndex((it) => it.id === id);
      if (i === -1) return false;
      items.splice(i, 1);
      return true;
    },
  };
}

describe('backend API', () => {
  let db;
  let app;

  beforeEach(() => {
    db = fakeDb();
    app = createApp({ db, version: 'test' });
  });

  it('GET /healthz returns ok', async () => {
    const res = await request(app).get('/healthz').expect(200);
    assert.equal(res.body.status, 'ok');
  });

  it('GET /readyz reflects database health', async () => {
    await request(app).get('/readyz').expect(200);
    db.healthy = false;
    await request(app).get('/readyz').expect(503);
  });

  it('GET /api/info returns hostname and version', async () => {
    const res = await request(app).get('/api/info').expect(200);
    assert.equal(res.body.version, 'test');
    assert.ok(res.body.hostname);
  });

  it('creates, lists and deletes items', async () => {
    const created = await request(app).post('/api/items').send({ name: '  hello  ' }).expect(201);
    assert.equal(created.body.name, 'hello');

    const list = await request(app).get('/api/items').expect(200);
    assert.equal(list.body.length, 1);

    await request(app).delete(`/api/items/${created.body.id}`).expect(204);
    await request(app).delete(`/api/items/${created.body.id}`).expect(404);
  });

  it('rejects invalid input', async () => {
    await request(app).post('/api/items').send({}).expect(400);
    await request(app).post('/api/items').send({ name: 'x'.repeat(201) }).expect(400);
    await request(app).delete('/api/items/abc').expect(400);
  });
});
