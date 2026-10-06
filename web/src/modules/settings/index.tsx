import { useState, type FormEvent, type ChangeEvent } from 'react';
import { Check, Download, Upload, HardDrive, Blocks } from 'lucide-react';
import { useQueryClient } from '@tanstack/react-query';
import type { Preferences } from '../../../shared/schema';
import { MAX_BACKUP_BYTES, BACKUP_LIMIT_LABEL } from '../../../shared/backup';
import { api, download, useCommand } from '../../lib/api';
import { useSettings } from './api';
import { PageHeader, ErrorMessage, Loading, Badge, Confirm } from '../../components/ui';
import { ProfileSettings } from '../workspace/profile';
import { clearExploreAfterImport } from '../news/explore-api';

function PreferencesForm({ preferences }: { preferences: Preferences }) {
  const command = useCommand(['settings']);
  const [draft, setDraft] = useState(preferences), [saved, setSaved] = useState(false);
  async function submit(e: FormEvent) {
    e.preventDefault(); setSaved(false);
    try { await command.mutateAsync({ path: '/settings/preferences', method: 'PUT', body: draft }); setSaved(true); } catch { /* Retain draft. */ }
  }
  return <form className="panel editor" onSubmit={submit}><div className="section-title"><h2>Make yourself at home.</h2><Badge>Preferences</Badge></div>
    <label>Default Focus duration <span className="muted">(minutes)</span><input type="number" required min={1} max={1440} value={draft.focusDefaultMinutes} onChange={e => { setSaved(false); setDraft({ ...draft, focusDefaultMinutes: Number(e.target.value) }); }} /></label>
    <p className="footnote">Changes apply to your next session. A running session keeps its duration.</p>
    <div className="form-grid"><label>Text size<select value={draft.textSize} onChange={e => { setSaved(false); setDraft({ ...draft, textSize: e.target.value as Preferences['textSize'] }); }}><option value="system">Standard</option><option value="large">Large</option></select></label>
      <label>Motion<select value={draft.reduceMotion} onChange={e => { setSaved(false); setDraft({ ...draft, reduceMotion: e.target.value as Preferences['reduceMotion'] }); }}><option value="system">Follow system</option><option value="reduce">Reduce motion</option></select></label></div>
    <ErrorMessage error={command.error} /><div className="actions"><button className="button primary" disabled={command.isPending}>Save preferences</button>{saved && <span className="success-text" role="status"><Check size={14} /> Saved</span>}</div>
  </form>;
}
interface ImportSummary { source: string; sessions: number; lessons: number; answers: number; feeds: number }
export function SettingsPage() {
  const query = useSettings(), command = useCommand(['settings']), client = useQueryClient();
  const [error, setError] = useState<Error | null>(null), [busy, setBusy] = useState(false), [done, setDone] = useState(false);
  const [pendingImport, setImport] = useState<{ source: unknown; summary: ImportSummary } | null>(null);
  async function preview(e: ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]; if (!file) return;
    setBusy(true); setError(null); setDone(false); setImport(null);
    try {
      if (file.size > MAX_BACKUP_BYTES) throw new Error('Choose a JSON export no larger than ' + BACKUP_LIMIT_LABEL + '.');
      const source: unknown = JSON.parse(await file.text());
      const summary = await api<ImportSummary>('/settings/import/preview', 'POST', source);
      setImport({ source, summary });
    } catch (error) { setError(error instanceof SyntaxError ? new Error('This file is not valid JSON.') : error as Error); }
    finally { setBusy(false); e.target.value = ''; }
  }
  async function importRecords() {
    if (!pendingImport) return;
    setBusy(true); setError(null);
    try {
      await api('/settings/import', 'POST', pendingImport.source);
      clearExploreAfterImport(client);
      await client.invalidateQueries(); setImport(null); setDone(true);
    }
    catch (error) { setError(error as Error); } finally { setBusy(false); }
  }
  async function backup() {
    setBusy(true); setError(null);
    try { download('kontrol-web-' + new Date().toISOString().slice(0, 10) + '.json', await api('/settings/export')); }
    catch (error) { setError(error as Error); } finally { setBusy(false); }
  }
  return <><PageHeader eyebrow="YOUR WORKSPACE, YOUR WAY" title="Settings" description="A few thoughtful defaults. Everything saved on this Mac." />
    <ProfileSettings />
    <ErrorMessage error={query.error} />{query.isPending ? <Loading /> : query.data && <PreferencesForm key={JSON.stringify(query.data.preferences)} preferences={query.data.preferences} />}
    <div className="settings-grid"><div className="panel"><Blocks size={23} className="accent-text" /><h2>A dashboard that fits.</h2><p className="muted">Choose which widgets you see, change their width, and put them in the order that makes sense to you.</p>
      <a className="button secondary" href="#/?customize=1">Customize dashboard</a></div><div className="panel"><HardDrive size={23} className="accent-text" /><h2>Local by design.</h2><p className="muted">Your data stays on this computer. Connected project files stay in their original folders.</p><Badge tone="success">No account required</Badge></div></div>
    <div className="panel"><div className="section-title"><h2>Your data belongs to you.</h2><Badge>Data transfer</Badge></div><p className="muted">Import a Kontrol backup or a version 1 JSON export from the former macOS app. Imports require an empty workspace and are validated before anything is written.</p>
      <p className="footnote">Backups include goals, saved articles and notes, lesson bookmarks and reviews, application history, follow-up dates, learning, Focus, news interests, feeds, Jobs and preferences. Jobs includes extracted CV text and your reviewed profile. Records from earlier versions are retained. Reconnect project folders separately. Credentials are excluded. Backups contain personal content as unencrypted plain text.</p>
      <div className="actions"><button className="button secondary" onClick={() => void backup()} disabled={busy}><Download size={16} /> Export backup</button><label className={'button secondary file-button ' + (busy ? 'disabled' : '')}><Upload size={16} /> Import JSON<input type="file" accept=".json,application/json" disabled={busy} onChange={e => void preview(e)} /></label></div>
      <ErrorMessage error={error ?? command.error} />{busy && <p role="status" className="muted">Working with your data…</p>}
      {pendingImport && <><div className="import-stats">{Object.entries(pendingImport.summary).map(([key, value]) => <div key={key}><span className="row-meta">{key}</span><strong>{value}</strong></div>)}</div>
        <Confirm title="Import these records?" description="The import will be rejected if this workspace already contains personal work." label="Import records" pending={busy} onConfirm={() => void importRecords()} onCancel={() => setImport(null)} /></>}
      {done && <div className="success-note" role="status"><Check size={16} /> Import complete. Your saved work is ready in the dashboard.</div>}
    </div>
    <div className="panel"><h2>About Kontrol</h2><p className="muted">Kontrol 0.1 · All 40 starter lessons are included. Previously generated lessons can be imported; creating new AI lessons is not supported.</p>
      <p className="muted">News includes cross-source discovery and optional AI web search. AI search uses your existing PI login and model to interpret specific interests. Check the PI connection in News; standard search needs no key.</p>
      <p className="muted">Jobs uses the same PI connection to analyze an uploaded CV and match retrieved job offers to your reviewed profile, work arrangements, employment types and cities.</p>
      <p className="footnote">The server listens on this Mac only. Keep it running while using the dashboard. No cloud sync or remote access is configured.</p></div>
  </>;
}
