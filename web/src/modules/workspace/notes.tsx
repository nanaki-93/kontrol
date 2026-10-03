import { useState, type FormEvent } from 'react';
import { Plus, Pencil, Trash2 } from 'lucide-react';
import type { Note } from '../../../shared/workspace';
import { Confirm, ErrorMessage, formatDate } from '../../components/ui';
import { useWorkspace, useWorkspaceCommand } from './api';

export function NoteEditor({ note, project, onClose }: { note?: Note; project?: { title: string; body: string }; onClose?: () => void }) {
  const command = useWorkspaceCommand();
  const [title, setTitle] = useState(note?.title ?? project?.title ?? ''), [body, setBody] = useState(note?.body ?? project?.body ?? '');
  const [url, setURL] = useState(note?.url ?? ''), [kind, setKind] = useState<Note['kind']>(note?.kind ?? (project ? 'project' : 'note'));
  const [baseline, setBaseline] = useState(note?.revision), [saved, setSaved] = useState(false);
  async function submit(event: FormEvent) {
    event.preventDefault(); setSaved(false);
    try {
      const result = await command.mutateAsync({ path: note ? '/notes/' + note.id : '/notes', method: note ? 'PUT' : 'POST', body: { title, body, url: url || null, kind, expectedRecordRevision: baseline } });
      if (note) setBaseline(result.notes.find(n => n.id === note.id)?.revision);
      else { setTitle(''); setBody(''); setURL(''); }
      setSaved(true); onClose?.();
    } catch { /* Preserve the note until it is saved. */ }
  }
  return <form className="editor note-editor" onSubmit={event => void submit(event)} onChange={() => setSaved(false)}>
    <div className="form-grid"><label>Title<input required maxLength={200} value={title} onChange={e => setTitle(e.target.value)} placeholder="Something to remember" /></label>
      <label>Save as<select value={kind} onChange={e => setKind(e.target.value as Note['kind'])}><option value="note">Note</option><option value="link">Pinned link</option><option value="project">Practice project</option></select></label></div>
    <label>Notes<textarea rows={4} maxLength={20_000} value={body} onChange={e => setBody(e.target.value)} placeholder="Capture an idea, a takeaway, or evidence of your practice." /></label>
    <label>Link {kind !== 'link' && '(optional)'}<input type="url" required={kind === 'link'} maxLength={4096} value={url} onChange={e => setURL(e.target.value)} placeholder="https://" /></label>
    <ErrorMessage error={command.error} /><div className="actions"><button className="button primary" disabled={command.isPending}><Plus size={14} />Save {kind === 'link' ? 'link' : kind === 'project' ? 'project' : 'note'}</button>
      {onClose && <button type="button" className="button secondary" onClick={onClose}>Close</button>}{saved && <span className="success-text" role="status">Saved to your library</span>}
      {command.error && note && <button type="button" className="button secondary" onClick={() => { setBaseline(note.revision); command.reset(); }}>Keep my draft for the next save</button>}</div>
    {command.error && note && <details><summary>Review the currently saved note</summary><h3>{note.title}</h3><p className="prose-text">{note.body}</p>{note.url && <p>{note.url}</p>}</details>}
  </form>;
}
export function NoteCard({ note }: { note: Note }) {
  const command = useWorkspaceCommand(), [editing, setEditing] = useState(false), [removing, setRemoving] = useState(false);
  return <article className="panel"><div className="section-title"><div><span className="eyebrow">{note.kind}</span><h3>{note.title}</h3></div><div className="actions">
    <button className="icon-button" aria-label={'Edit ' + note.title} onClick={() => setEditing(!editing)}><Pencil size={16} /></button>
    <button className="icon-button" aria-label={'Delete ' + note.title} onClick={() => setRemoving(true)}><Trash2 size={16} /></button></div></div>
    {editing ? <NoteEditor note={note} onClose={() => setEditing(false)} /> : <><p className="prose-text">{note.body}</p>{note.url && <a className="text-link break-word" href={note.url} target="_blank" rel="noreferrer">Open link ↗</a>}<p className="footnote">Updated {formatDate(note.updatedAt)}</p></>}
    <ErrorMessage error={command.error} />{removing && <Confirm title={'Delete “' + note.title + '”?'} description="This removes the note from your library." label="Delete note" pending={command.isPending} onCancel={() => setRemoving(false)} onConfirm={() => command.mutate({ path: '/notes/' + note.id, method: 'DELETE', body: { expectedRecordRevision: note.revision } })} />}
  </article>;
}
export function QuickCapture() {
  const query = useWorkspace(), [open, setOpen] = useState(false);
  return <section className="panel"><div className="section-title"><h2>Quick notes & links</h2><button className="text-link" onClick={() => setOpen(!open)}><Plus size={14} />{open ? 'Close editor' : 'Capture something'}</button></div>
    {open && <NoteEditor onClose={() => setOpen(false)} />}
    <div className="pinned-links">{query.data?.notes.filter(n => n.kind === 'link' && n.url).slice(0, 6).map(n => <a className="button secondary" href={n.url!} target="_blank" rel="noreferrer" key={n.id}>{n.title} ↗</a>)}</div>
    {!open && !query.data?.notes.length && <p className="muted">Keep useful links, thoughts, and project evidence close at hand.</p>}
    <a className="text-link" href="#/library">Open saved library →</a>
  </section>;
}
