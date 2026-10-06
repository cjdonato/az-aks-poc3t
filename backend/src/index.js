import { createApp } from './app.js';
import { createDb } from './db.js';

const port = Number(process.env.PORT ?? 3000);
const db = createDb();

// Retry migrations so the API survives starting before the database is reachable.
async function migrateWithRetry(attempts = 10, delayMs = 3000) {
  for (let i = 1; ; i++) {
    try {
      return await db.migrate();
    } catch (err) {
      if (i >= attempts) throw err;
      console.warn(`migration attempt ${i}/${attempts} failed: ${err.message}; retrying`);
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
}

await migrateWithRetry();

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
