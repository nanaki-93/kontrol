import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, cpSync, readFileSync, writeFileSync, rmSync, symlinkSync, mkdirSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Store } from '../server/store';
import { parseFeature, patchCompletion, inspectProject, safePath } from '../server/modules/projects';
import { withAPI } from './helpers';
import type { ProjectInspection, ProjectReference } from '../shared/schema';

function fixture(): string {
  const root = mkdtempSync(join(tmpdir(), 'kontrol-web-test-'));
  cpSync(fileURLToPath(new URL('../../docs/examples/.kontrol', import.meta.url)), join(root, '.kontrol'), { recursive: true });
  return realpathSync(root);
}
test('SQLite survives reopening and transaction failures preserve previous data', () => {
  const root = mkdtempSync(join(tmpdir(), 'kontrol-web-sqlite-')), path = join(root, 'test.sqlite');
  try {
    let store = new Store(path);
    store.set('fixture', { exact: ' \nUnicode é\u0301' });
    assert.throws(() => store.transaction(() => { store.set('fixture', { exact: 'bad' }); throw new Error('abort'); }));
    store.close();
    store = new Store(path);
    assert.deepEqual(store.get('fixture'), { exact: ' \nUnicode é\u0301' });
    store.close();
  } finally { rmSync(root, { recursive: true, force: true }); }
});
test('project parser preserves comments, unknown keys, Markdown, CRLF and nested status', () => {
  const source = '---\r\nid: test\r\ntitle: Test\r\nstatus: ready # comment\r\npriority: high\r\neffort: small\r\ncustom:\r\n  status: keep-me\r\ncompleted_at:\r\n---\r\n# Body\r\nstatus: untouched\r\n';
  const next = patchCompletion(source, '2026-10-02T08:00:00.000Z');
  assert.equal(parseFeature(next, 'test.md').status, 'completed');
  assert.ok(next.includes('status: "completed" # comment\r\n'));
  assert.ok(next.includes('  status: keep-me\r\n'));
  assert.equal(next.slice(next.lastIndexOf('---')), source.slice(source.lastIndexOf('---')));
  assert.equal(next.replaceAll('\r\n', '').includes('\n'), false);
});
test('ambiguous and duplicate YAML is rejected without rewriting', () => {
  const source = '---\nid: test\ntitle: Test\nstatus: ready\nstatus: blocked\npriority: high\neffort: small\n---\nBody';
  assert.throws(() => parseFeature(source, 'test.md'));
  assert.throws(() => patchCompletion(source, new Date().toISOString()));
});
test('dependency cycles and missing dependencies cannot appear as next features', () => {
  const root = fixture();
  try {
    writeFileSync(join(root, '.kontrol/features/cycle.md'), '---\nid: cycle\ntitle: Cycle\nstatus: ready\npriority: high\neffort: small\ndepends_on: [cycle]\n---\nBody');
    const ref: ProjectReference = { id: 'fixture', path: root, manifestID: 'kontrol-example', name: 'Example' };
    const result = inspectProject(ref);
    assert.equal(result.candidates.includes('cycle'), false);
    assert.ok(result.errors.some(e => e.includes('cycle')));
    assert.ok(result.candidates.includes('project-reader'));
  } finally { rmSync(root, { recursive: true, force: true }); }
});
test('project reads reject traversal and nested symbolic links', () => {
  const root = fixture(), outside = mkdtempSync(join(tmpdir(), 'kontrol-web-outside-'));
  try {
    writeFileSync(join(outside, 'secret.md'), 'fixture secret');
    symlinkSync(join(outside, 'secret.md'), join(root, '.kontrol/features/escape.md'));
    assert.throws(() => safePath(root, '../secret.md'));
    assert.throws(() => safePath(root, '.kontrol/features/escape.md'));
    const result = inspectProject({ id: 'fixture', path: root, manifestID: 'kontrol-example', name: 'Example' });
    assert.ok(result.errors.some(e => e.includes('Symbolic links')));
    assert.equal(JSON.stringify(result).includes('fixture secret'), false);
  } finally { rmSync(root, { recursive: true, force: true }); rmSync(outside, { recursive: true, force: true }); }
});
test('completion and Undo detect conflicts; disconnect never changes external project files', async () => {
  const root = fixture(), file = join(root, '.kontrol/features/project-reader.md');
  try {
    await withAPI(async ({ request }) => {
      const add = await request('/projects', 'POST', { path: root });
      assert.equal(add.status, 201);
      const project = await add.json() as ProjectInspection;
      const feature = project.features.find(f => f.id === 'project-reader')!;
      const original = readFileSync(file, 'utf8');
      const endpoint = '/projects/' + project.reference.id + '/features/project-reader';
      writeFileSync(file, original + '\nExternal edit\n');
      assert.equal((await request(endpoint + '/complete', 'POST', { expectedDigest: feature.digest })).status, 409);
      assert.equal(readFileSync(file, 'utf8'), original + '\nExternal edit\n');
      writeFileSync(file, original);
      assert.equal((await request(endpoint + '/complete', 'POST', { expectedDigest: feature.digest })).status, 200);
      assert.equal(parseFeature(readFileSync(file, 'utf8'), file).status, 'completed');
      assert.equal((await request(endpoint + '/undo', 'POST')).status, 200);
      assert.equal(readFileSync(file, 'utf8'), original);
      await request(endpoint + '/complete', 'POST', { expectedDigest: feature.digest });
      const changed = readFileSync(file, 'utf8') + '\nNew external edit\n';
      writeFileSync(file, changed);
      assert.equal((await request(endpoint + '/undo', 'POST')).status, 409);
      assert.equal((await request('/projects/' + project.reference.id, 'DELETE')).status, 204);
      assert.equal(readFileSync(file, 'utf8'), changed);
    });
  } finally { rmSync(root, { recursive: true, force: true }); }
});
test('unsupported future SQLite schema does not get reset', () => {
  const root = mkdtempSync(join(tmpdir(), 'kontrol-web-schema-'));
  try {
    mkdirSync(join(root, 'data'));
    const path = join(root, 'data', 'fixture.sqlite');
    const store = new Store(path);
    store.set('fixture', { preserve: true });
    store.db.exec('PRAGMA user_version = 999');
    store.close();
    assert.throws(() => new Store(path), /newer Kontrol/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
