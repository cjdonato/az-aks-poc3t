import fs from 'node:fs/promises';
import path from 'node:path';
import pg from 'pg';

const MIGRATIONS_DIR = path.join(import.meta.dirname, '..', 'migrations');
// Arbitrary constant so concurrent replicas don't run migrations at the same time.
const MIGRATION_LOCK_ID = 727274;

// Retries an async operation, e.g. so startup survives a database that isn't reachable yet.
export async function withRetry(fn, { attempts = 10, delayMs = 3000, label = 'operation' } = {}) {
  for (let i = 1; ; i++) {
    try {
      return await fn();
    } catch (err) {
      if (i >= attempts) throw err;
      console.warn(`${label} attempt ${i}/${attempts} failed: ${err.message}; retrying`);
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
}

// Connection settings come from the standard libpq env vars
// (PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE, PGSSLMODE), which pg reads natively.
// Azure Database for PostgreSQL requires TLS, so set PGSSLMODE=require there.
export function createDb(pool = new pg.Pool({ max: 10 })) {
  return {
    pool,

    async ping() {
      await pool.query('SELECT 1');
    },

    async listItems() {
      const { rows } = await pool.query(
        'SELECT id, name, created_at FROM items ORDER BY id DESC',
      );
      return rows;
    },

    async createItem(name) {
      const { rows } = await pool.query(
        'INSERT INTO items (name) VALUES ($1) RETURNING id, name, created_at',
        [name],
      );
      return rows[0];
    },

    async deleteItem(id) {
      const { rowCount } = await pool.query('DELETE FROM items WHERE id = $1', [id]);
      return rowCount > 0;
    },

    // Applies migrations/*.sql in filename order, each once, tracked in schema_migrations.
    async migrate() {
      const client = await pool.connect();
      try {
        await client.query('SELECT pg_advisory_lock($1)', [MIGRATION_LOCK_ID]);
        await client.query(`
          CREATE TABLE IF NOT EXISTS schema_migrations (
            name TEXT PRIMARY KEY,
            applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
          )`);
        const { rows } = await client.query('SELECT name FROM schema_migrations');
        const applied = new Set(rows.map((r) => r.name));

        const files = (await fs.readdir(MIGRATIONS_DIR)).filter((f) => f.endsWith('.sql')).sort();
        for (const file of files) {
          if (applied.has(file)) continue;
          const sql = await fs.readFile(path.join(MIGRATIONS_DIR, file), 'utf8');
          await client.query('BEGIN');
          try {
            await client.query(sql);
            await client.query('INSERT INTO schema_migrations (name) VALUES ($1)', [file]);
            await client.query('COMMIT');
            console.log(`migration applied: ${file}`);
          } catch (err) {
            await client.query('ROLLBACK');
            throw err;
          }
        }
      } finally {
        await client.query('SELECT pg_advisory_unlock($1)', [MIGRATION_LOCK_ID]).catch(() => {});
        client.release();
      }
    },

    // Creates (or updates the password of) the application login and limits it to
    // reading and writing rows: no DDL, no access to the migrations table.
    // Run as the role that owns the tables (the one that ran migrate()).
    async ensureAppRole(user, password) {
      const client = await pool.connect();
      try {
        // Role statements can't take bind parameters, so escape instead.
        const role = client.escapeIdentifier(user);
        const secret = client.escapeLiteral(password);
        const { rowCount: exists } = await client.query(
          'SELECT 1 FROM pg_roles WHERE rolname = $1',
          [user],
        );
        // Attributes are set only on create: a non-superuser admin (as on Azure) may
        // not touch CREATEDB/CREATEROLE in ALTER ROLE, even to switch them off.
        await client.query(
          exists
            ? `ALTER ROLE ${role} LOGIN PASSWORD ${secret}`
            : `CREATE ROLE ${role} LOGIN NOCREATEDB NOCREATEROLE PASSWORD ${secret}`,
        );

        const { rows } = await client.query('SELECT current_database() AS name');
        const database = client.escapeIdentifier(rows[0].name);
        await client.query(`
          REVOKE CREATE ON SCHEMA public FROM PUBLIC;
          GRANT CONNECT ON DATABASE ${database} TO ${role};
          GRANT USAGE ON SCHEMA public TO ${role};
          GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${role};
          GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ${role};
          REVOKE ALL ON schema_migrations FROM ${role};
          -- Tables and sequences created by later migrations get the same grants.
          ALTER DEFAULT PRIVILEGES IN SCHEMA public
            GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${role};
          ALTER DEFAULT PRIVILEGES IN SCHEMA public
            GRANT USAGE, SELECT ON SEQUENCES TO ${role};
        `);
        console.log(`app role ensured: ${user}`);
      } finally {
        client.release();
      }
    },
  };
}
