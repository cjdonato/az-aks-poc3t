// One-shot database setup, run as the server admin before the backend starts
// (on AKS: the db-migrate Helm hook). Applies migrations, then ensures the
// least-privilege application role the backend connects with.
//
// Env: the libpq PG* variables for the admin connection, plus
//   PGPASSWORD_FILE       admin password file (instead of PGPASSWORD)
//   APP_DB_USER           application role to create/update (optional)
//   APP_DB_PASSWORD_FILE  its password file
import fs from 'node:fs';
import pg from 'pg';
import { createDb, withRetry } from './db.js';

const readSecretFile = (envName) => {
  const file = process.env[envName];
  if (!file) throw new Error(`${envName} is not set`);
  return fs.readFileSync(file, 'utf8').trim();
};

const pool = new pg.Pool({
  max: 1,
  // Secrets come as files from the Key Vault CSI mount; fall back to PGPASSWORD.
  ...(process.env.PGPASSWORD_FILE && { password: readSecretFile('PGPASSWORD_FILE') }),
});
const db = createDb(pool);

try {
  await withRetry(() => db.migrate(), { label: 'migration' });
  if (process.env.APP_DB_USER) {
    await db.ensureAppRole(process.env.APP_DB_USER, readSecretFile('APP_DB_PASSWORD_FILE'));
  }
} finally {
  await pool.end();
}
