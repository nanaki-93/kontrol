import { Router } from 'express';
import { createHash, randomUUID } from 'node:crypto';
import {
  realpathSync, lstatSync, readdirSync, openSync, closeSync, readFileSync,
  writeFileSync, renameSync, unlinkSync, constants, fstatSync, fsyncSync,
} from 'node:fs';
import { isAbsolute, join, relative, sep, dirname } from 'node:path';
import { parseDocument, isMap, isScalar } from 'yaml';
import { z } from 'zod';
import { id, title, type Feature, type ProjectReference, type ProjectInspection } from '../../shared/schema';
import { Store } from '../store';
import { HttpError, requireFound } from '../errors';

const strings = z.array(id);
const manifestSchema = z.object({
  schema_version: z.literal(1), id, name: title, description: z.string().default(''),
  stack: strings.default([]), goals: z.array(z.string()).default([]), current_focus: strings.default([]),
});
const featureSchema = z.object({
  schema_version: z.literal(1).optional(), id, title,
  status: z.enum(['planned', 'ready', 'active', 'blocked', 'completed']),
  priority: z.enum(['high', 'medium', 'low']), effort: z.enum(['small', 'medium', 'large']),
  depends_on: strings.default([]), areas: strings.default([]), completed_at: z.string().nullable().default(null),
});
export const digest = (text: string): string => createHash('sha256').update(text).digest('hex');

// The selected canonical root is the only authority. Never follow nested links,
// including .kontrol itself, on reads or just before committing writes.
export function safePath(root: string, path: string): string {
  if (lstatSync(root).isSymbolicLink() || realpathSync(root) !== root) throw new HttpError(409, 'The project folder moved. Reconnect it.');
  const resolved = join(root, path);
  const rel = relative(root, resolved);
  if (rel.startsWith('..' + sep) || rel === '..' || isAbsolute(rel)) throw new HttpError(400, 'Path escapes the project folder.');
  let part = root;
  for (const segment of rel.split(sep)) {
    part = join(part, segment);
    if (lstatSync(part).isSymbolicLink()) throw new HttpError(400, 'Symbolic links inside .kontrol are not supported.');
  }
  return resolved;
}
function readBounded(root: string, file: string): string {
  const fd = openSync(safePath(root, file), constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.size > 1_048_576) throw new HttpError(400, file + ': expected a text file of at most 1 MB.');
    const bytes = readFileSync(fd);
    if (bytes.length > 1_048_576) throw new HttpError(400, file + ': file exceeds 1 MB.');
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } finally { closeSync(fd); }
}
function yaml(source: string): unknown {
  const doc = parseDocument(source, { uniqueKeys: true });
  if (doc.errors.length || !isMap(doc.contents)) throw new HttpError(400, 'Invalid YAML mapping or duplicate key.');
  return doc.toJS({ maxAliasCount: 0 });
}
export function frontmatter(source: string): { start: number; end: number; bodyStart: number; yaml: string } {
  const match = /^---\r?\n/.exec(source);
  if (!match) throw new HttpError(400, 'A feature must begin with YAML frontmatter.');
  const closing = /^---[ \t]*\r?$/gm;
  closing.lastIndex = match[0].length;
  const end = closing.exec(source);
  if (!end) throw new HttpError(400, 'Missing frontmatter closing delimiter.');
  return { start: match[0].length, end: end.index,
    bodyStart: end.index + end[0].length + (source[end.index + end[0].length] === '\n' ? 1 : 0),
    yaml: source.slice(match[0].length, end.index) };
}
export function parseFeature(source: string, file: string): Feature {
  const fm = frontmatter(source);
  return { ...featureSchema.parse(yaml(fm.yaml)), body: source.slice(fm.bodyStart), file, digest: digest(source) };
}
export function patchCompletion(source: string, at: string): string {
  const fm = frontmatter(source);
  const doc = parseDocument(fm.yaml, { uniqueKeys: true });
  if (doc.errors.length || !isMap(doc.contents) || doc.contents.flow) throw new HttpError(400, 'Only block-style feature frontmatter can be updated safely.');
  const edits: { start: number; end: number; value: string }[] = [];
  for (const [key, value] of [['status', 'completed'], ['completed_at', at]]) {
    const node = doc.get(key, true);
    if (node === undefined && key === 'completed_at') {
      const newline = source.includes('\r\n') ? '\r\n' : '\n';
      edits.push({ start: fm.end, end: fm.end, value: 'completed_at: ' + JSON.stringify(value) + newline });
    } else {
      if (!isScalar(node) || !node.range || node.anchor || node.type === 'BLOCK_LITERAL' || node.type === 'BLOCK_FOLDED') {
        throw new HttpError(400, 'Cannot safely patch ' + key + '. Use a simple top-level scalar.');
      }
      const start = fm.start + node.range[0];
      const needsSpace = node.range[0] === node.range[1] && !/[ \t]/.test(source[start - 1]);
      edits.push({ start, end: fm.start + node.range[1], value: (needsSpace ? ' ' : '') + JSON.stringify(value) });
    }
  }
  let next = source;
  for (const edit of edits.sort((a, b) => b.start - a.start)) next = next.slice(0, edit.start) + edit.value + next.slice(edit.end);
  const checked = parseFeature(next, '');
  if (checked.status !== 'completed' || checked.completed_at !== at) throw new HttpError(400, 'Could not verify the feature update.');
  return next;
}

export function inspectProject(reference: ProjectReference): ProjectInspection {
  const result: ProjectInspection = { reference, manifest: null, features: [], candidates: [], roadmap: [], context: null, rules: null, errors: [] };
  const root = reference.path;
  try {
    const manifest = manifestSchema.parse(yaml(readBounded(root, '.kontrol/project.yaml')));
    if (manifest.id !== reference.manifestID) throw new HttpError(409, 'The project identity changed. Disconnect and add this folder again.');
    result.manifest = manifest;
  } catch (error) { result.errors.push('.kontrol/project.yaml: ' + errorText(error)); return result; }
  for (const name of ['context', 'rules'] as const) {
    try { result[name] = readBounded(root, '.kontrol/' + name + '.md'); }
    catch (error) { if (!isMissing(error)) result.errors.push(name + '.md: ' + errorText(error)); }
  }
  try {
    const roadmap = z.object({ schema_version: z.literal(1),
      milestones: z.array(z.object({ id, title, status: id })),
    }).parse(yaml(readBounded(root, '.kontrol/roadmap.yaml')));
    result.roadmap = roadmap.milestones;
  } catch (error) { if (!isMissing(error)) result.errors.push('roadmap.yaml: ' + errorText(error)); }
  try {
    const files = readdirSync(safePath(root, '.kontrol/features')).filter(f => f.endsWith('.md')).sort();
    if (files.length > 500) throw new HttpError(400, 'At most 500 feature files are supported.');
    for (const name of files) {
      const file = '.kontrol/features/' + name;
      try { result.features.push(parseFeature(readBounded(root, file), file)); }
      catch (error) { result.errors.push(file + ': ' + errorText(error)); }
    }
  } catch (error) { result.errors.push('features: ' + errorText(error)); }
  const invalid = new Set<string>(), byID = new Map<string, Feature>();
  for (const feature of result.features) {
    if (byID.has(feature.id)) { invalid.add(feature.id); result.errors.push('Duplicate feature id: ' + feature.id); }
    byID.set(feature.id, feature);
  }
  const visited = new Set<string>(), visiting = new Set<string>();
  function visit(feature: Feature): boolean {
    if (visiting.has(feature.id)) { invalid.add(feature.id); return false; }
    if (visited.has(feature.id)) return !invalid.has(feature.id);
    visiting.add(feature.id);
    for (const dep of feature.depends_on) if (!byID.has(dep) || !visit(byID.get(dep)!)) invalid.add(feature.id);
    visiting.delete(feature.id); visited.add(feature.id);
    return !invalid.has(feature.id);
  }
  for (const feature of result.features) visit(feature);
  if (invalid.size) result.errors.push('Invalid dependencies, cycles or duplicate IDs: ' + [...invalid].join(', '));
  const priority = ['high', 'medium', 'low'], effort = ['small', 'medium', 'large'];
  const focused = (f: Feature) => f.areas.some(a => result.manifest!.current_focus.includes(a));
  result.candidates = result.features.filter(f => !invalid.has(f.id) && f.status === 'ready' &&
    f.depends_on.every(dep => byID.get(dep)?.status === 'completed'))
    .sort((a, b) => Number(focused(b)) - Number(focused(a)) || priority.indexOf(a.priority) - priority.indexOf(b.priority) ||
      effort.indexOf(a.effort) - effort.indexOf(b.effort) || a.id.localeCompare(b.id))
    .slice(0, 3).map(f => f.id);
  return result;
}
function isMissing(error: unknown): boolean { return (error as NodeJS.ErrnoException).code === 'ENOENT'; }
function errorText(error: unknown): string {
  if (error instanceof HttpError) return error.message;
  if (error instanceof z.ZodError) return error.issues.map(x => x.path.join('.') + ': ' + x.message).join('; ');
  return 'Could not read a valid file. Check the folder, format and permissions.';
}
function replaceFeature(root: string, file: string, expected: string, contents: string): void {
  const path = safePath(root, file), before = readBounded(root, file);
  if (digest(before) !== expected) throw new HttpError(409, 'The feature changed on disk. Refresh and review it before trying again.');
  const mode = lstatSync(path).mode & 0o777;
  const temp = join(dirname(path), '.kontrol-' + randomUUID() + '.tmp');
  let created = false;
  try {
    const fd = openSync(temp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, mode);
    created = true;
    try { writeFileSync(fd, contents, 'utf8'); fsyncSync(fd); } finally { closeSync(fd); }
    safePath(root, file);
    if (digest(readBounded(root, file)) !== expected) throw new HttpError(409, 'The feature changed before saving. Refresh and try again.');
    renameSync(temp, path); created = false;
    if (readBounded(root, file) !== contents) throw new HttpError(409, 'The file changed during verification. Refresh to inspect its current state.');
  } finally { if (created) unlinkSync(temp); }
}
export function projectsModule(store: Store): Router {
  const router = Router();
  const undo = new Map<string, { file: string; before: string; after: string }>();
  store.init<ProjectReference[]>('projects', []);
  router.get('/', (_req, res) => res.json(store.get<ProjectReference[]>('projects').map(inspectProject)));
  router.post('/', (req, res) => {
    const { path } = z.object({ path: z.string().min(1).max(4096) }).parse(req.body);
    if (!isAbsolute(path)) throw new HttpError(400, 'Enter the absolute path to a project folder.');
    let root: string;
    try { root = realpathSync(path); } catch { throw new HttpError(400, 'The folder could not be opened. Check its path and permissions.'); }
    const manifest = manifestSchema.parse(yaml(readBounded(root, '.kontrol/project.yaml')));
    const reference: ProjectReference = { id: randomUUID(), path: root, manifestID: manifest.id, name: manifest.name };
    const inspection = inspectProject(reference);
    store.transaction(() => {
      const refs = store.get<ProjectReference[]>('projects');
      if (refs.some(r => r.path === root || r.manifestID === manifest.id)) throw new HttpError(409, 'That project is already connected.');
      store.set('projects', [...refs, reference]);
    });
    res.status(201).json(inspection);
  });
  router.delete('/:id', (req, res) => {
    store.transaction(() => {
      const refs = store.get<ProjectReference[]>('projects');
      requireFound(refs.find(r => r.id === req.params.id));
      store.set('projects', refs.filter(r => r.id !== req.params.id));
      for (const key of undo.keys()) if (key.startsWith(req.params.id + ':')) undo.delete(key);
    });
    res.status(204).end();
  });
  router.post('/:id/features/:featureID/complete', (req, res) => {
    const { expectedDigest } = z.object({ expectedDigest: z.string().regex(/^[a-f0-9]{64}$/) }).parse(req.body);
    const ref = requireFound(store.get<ProjectReference[]>('projects').find(r => r.id === req.params.id));
    const inspection = inspectProject(ref);
    const feature = requireFound(inspection.features.find(f => f.id === req.params.featureID));
    if (!inspection.candidates.includes(feature.id)) throw new HttpError(409, 'Only a ready feature with completed dependencies can be completed.');
    const before = readBounded(ref.path, feature.file);
    if (digest(before) !== expectedDigest) throw new HttpError(409, 'The feature changed. Refresh and review it first.');
    const after = patchCompletion(before, new Date().toISOString());
    replaceFeature(ref.path, feature.file, expectedDigest, after);
    undo.set(ref.id + ':' + feature.id, { file: feature.file, before, after: digest(after) });
    res.json({ inspection: inspectProject(ref), undoDigest: digest(after) });
  });
  router.post('/:id/features/:featureID/undo', (req, res) => {
    const ref = requireFound(store.get<ProjectReference[]>('projects').find(r => r.id === req.params.id));
    if (!inspectProject(ref).manifest) throw new HttpError(409, 'The project identity or manifest changed. Refresh and review the folder before Undo.');
    const key = ref.id + ':' + req.params.featureID;
    const entry = requireFound(undo.get(key), 'Undo expired. Inspect the current project files.');
    replaceFeature(ref.path, entry.file, entry.after, entry.before);
    undo.delete(key);
    res.json(inspectProject(ref));
  });
  return router;
}
