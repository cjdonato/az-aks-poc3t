import os from 'node:os';
import express from 'express';

// The app takes its data-access layer as a dependency so tests can run without Postgres.
export function createApp({ db, version = process.env.APP_VERSION ?? 'dev' }) {
  const app = express();
  app.use(express.json());

  // Liveness: the process is up. Never touches the DB so a DB outage doesn't restart pods.
  app.get('/healthz', (_req, res) => res.json({ status: 'ok' }));

  // Readiness: only take traffic when the DB is reachable.
  app.get('/readyz', async (_req, res) => {
    try {
      await db.ping();
      res.json({ status: 'ready' });
    } catch (err) {
      res.status(503).json({ status: 'unavailable', error: err.message });
    }
  });

  // Shows which pod served the request — handy for seeing load balancing on AKS.
  app.get('/api/info', (_req, res) => {
    res.json({ hostname: os.hostname(), version });
  });

  app.get('/api/items', async (_req, res, next) => {
    try {
      res.json(await db.listItems());
    } catch (err) {
      next(err);
    }
  });

  app.post('/api/items', async (req, res, next) => {
    const name = typeof req.body?.name === 'string' ? req.body.name.trim() : '';
    if (!name || name.length > 200) {
      return res.status(400).json({ error: 'name is required (1-200 characters)' });
    }
    try {
      res.status(201).json(await db.createItem(name));
    } catch (err) {
      next(err);
    }
  });

  app.delete('/api/items/:id', async (req, res, next) => {
    const id = Number.parseInt(req.params.id, 10);
    if (!Number.isInteger(id) || id < 1) {
      return res.status(400).json({ error: 'invalid id' });
    }
    try {
      const deleted = await db.deleteItem(id);
      res.status(deleted ? 204 : 404).end();
    } catch (err) {
      next(err);
    }
  });

  app.use((_req, res) => res.status(404).json({ error: 'not found' }));

  // Express recognises error handlers by their 4-argument signature, so keep _next.
  app.use((err, _req, res, _next) => {
    console.error(err);
    res.status(500).json({ error: 'internal server error' });
  });

  return app;
}
