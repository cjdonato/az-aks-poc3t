import fs from 'node:fs/promises';
import path from 'node:path';
import pg from 'pg';

const MIGRATIONS_DIR = path.join(import.meta.dirname, '..', 'migrations');
// Arbitrary constant so concurrent replicas don't run migrations at the same time.
const MIGRATION_LOCK_ID = 727274;

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
  };
}
