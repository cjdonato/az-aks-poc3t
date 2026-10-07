import { createApp } from './app.js';
import { createDb, withRetry } from './db.js';

const port = Number(process.env.PORT ?? 3000);
const db = createDb();

// Locally the API migrates its own schema. On AKS it connects as a role without
// DDL rights, so RUN_MIGRATIONS=false and the db-migrate job does it instead.
if (process.env.RUN_MIGRATIONS !== 'false') {
  await withRetry(() => db.migrate(), { label: 'migration' });
}

const server = createApp({ db }).listen(port, () => {
  console.log(`backend listening on :${port}`);
});

// Kubernetes sends SIGTERM before killing a pod; finish in-flight requests first.
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    console.log(`${signal} received, shutting down`);
    server.close(async () => {
      await db.pool.end();
      process.exit(0);
    });
  });
}
