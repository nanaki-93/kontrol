import { DatabaseSync } from 'node:sqlite';
import { mkdirSync, chmodSync } from 'node:fs';
import { dirname } from 'node:path';

// Module-owned documents keep the persistence adapter small. Synchronous SQLite
// transactions serialize mutations, including multi-module import, in one process.
export class Store {
  readonly db: DatabaseSync;
  constructor(path: string) {
    if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    this.db = new DatabaseSync(path);
    if (path !== ':memory:') chmodSync(path, 0o600);
    this.db.exec('PRAGMA busy_timeout = 5000;');
    const version = this.db.prepare('PRAGMA user_version').get() as { user_version: number };
    if (version.user_version > 1) { this.db.close(); throw new Error('This database requires a newer Kontrol web app.'); }
    this.db.exec('PRAGMA journal_mode = WAL; CREATE TABLE IF NOT EXISTS documents (key TEXT PRIMARY KEY, value TEXT NOT NULL); PRAGMA user_version = 1;');
  }
  has(key: string): boolean { return !!this.db.prepare('SELECT 1 FROM documents WHERE key = ?').get(key); }
  get<T>(key: string): T {
    const row = this.db.prepare('SELECT value FROM documents WHERE key = ?').get(key) as { value: string } | undefined;
    if (!row) throw new Error('Missing persisted module: ' + key);
    return JSON.parse(row.value) as T;
  }
  set<T>(key: string, value: T): void {
    this.db.prepare('INSERT INTO documents(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
      .run(key, JSON.stringify(value));
  }
  init<T>(key: string, value: T): void { if (!this.has(key)) this.set(key, value); }
  transaction<T>(operation: () => T): T {
    this.db.exec('BEGIN IMMEDIATE');
    try { const value = operation(); this.db.exec('COMMIT'); return value; }
    catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
  close(): void { this.db.close(); }
}
