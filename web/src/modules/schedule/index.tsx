import { useState, type FormEvent } from 'react';
import { Plus, Pencil, Trash2, ArrowLeft, ArrowRight } from 'lucide-react';
import type { Block } from '../../../shared/schema';
import { dayKey, dateInput, overlap } from '../../../shared/dates';
import { useCommand } from '../../lib/api';
import { useSchedule } from './api';
import { PageHeader, Empty, ErrorMessage, Loading, Badge, Confirm, formatTime } from '../../components/ui';

function forDay(blocks: Block[], day: string): Block[] {
  const start = new Date(day + 'T00:00:00'), end = new Date(start);
  end.setDate(end.getDate() + 1);
  return blocks.filter(b => Date.parse(b.startAt) < end.getTime() && Date.parse(b.endAt) > start.getTime()).sort((a, b) => a.startAt.localeCompare(b.startAt));
}
function BlockEditor({ block, day, close }: { block: Block | null; day: string; close: () => void }) {
  const command = useCommand(['schedule']);
  const params = new URLSearchParams(window.location.hash.split('?')[1]);
  const [title, setTitle] = useState(block?.title ?? params.get('title') ?? '');
  const [start, setStart] = useState(block ? dateInput(block.startAt) : day + 'T09:00');
  const [end, setEnd] = useState(block ? dateInput(block.endAt) : day + 'T09:30');
  const [note, setNote] = useState(block?.note ?? ''), [allowOverlap, setAllowOverlap] = useState(false);
  async function submit(e: FormEvent) {
    e.preventDefault();
    try {
      await command.mutateAsync({ path: block ? '/schedule/' + block.id : '/schedule', method: block ? 'PUT' : 'POST',
        body: { title, startAt: new Date(start).toISOString(), endAt: new Date(end).toISOString(), note: note || null,
          lessonID: block?.lessonID ?? params.get('lesson'), linkedTitleSnapshot: block?.linkedTitleSnapshot ?? (params.get('lesson') ? title : null), allowOverlap } });
      close();
    } catch { /* Keep editable values. */ }
  }
  return <form className="panel editor" onSubmit={submit}><h2>{block ? 'Edit time block' : 'Make time for it.'}</h2>
    <label>Title<input required value={title} onChange={e => setTitle(e.target.value)} placeholder="What is this time for?" /></label>
    <div className="form-grid"><label>Starts<input type="datetime-local" required value={start} onChange={e => setStart(e.target.value)} /></label>
      <label>Ends<input type="datetime-local" required value={end} min={start} onChange={e => setEnd(e.target.value)} /></label></div>
    <label>Note<textarea rows={2} value={note} onChange={e => setNote(e.target.value)} /></label>
    <label className="checkbox-label"><input type="checkbox" checked={allowOverlap} onChange={e => setAllowOverlap(e.target.checked)} /> Allow this block to overlap existing plans</label>
    <ErrorMessage error={command.error} /><div className="actions"><button className="button primary" disabled={command.isPending}>Save block</button><button type="button" className="button secondary" onClick={close} disabled={command.isPending}>Cancel</button></div>
  </form>;
}
function Timeline({ blocks, edit }: { blocks: Block[]; edit?: (block: Block) => void }) {
  const command = useCommand(['schedule']), [removing, setRemoving] = useState<Block | null>(null);
  return <><ol className="timeline">{blocks.map(block => <li key={block.id}>
    <div className="timeline-time"><strong>{formatTime(block.startAt)}</strong><span>{formatTime(block.endAt)}</span></div>
    <div className="timeline-line"><i /></div>
    <div className="timeline-content"><div className="row-spread"><strong>{block.title}</strong>
      <div className="row-actions">{blocks.some(b => b.id !== block.id && overlap(block, b)) && <Badge tone="warning">Overlap</Badge>}
        {edit && <><button className="icon-button" onClick={() => edit(block)} aria-label={'Edit ' + block.title}><Pencil size={14} /></button><button className="icon-button" onClick={() => setRemoving(block)} aria-label={'Delete ' + block.title}><Trash2 size={14} /></button></>}</div></div>
      <div className="row-meta">{Math.round((Date.parse(block.endAt) - Date.parse(block.startAt)) / 60_000)} min{block.lessonID && <span>Learning</span>}</div>
      {block.note && <p className="task-notes">{block.note}</p>}</div>
  </li>)}</ol><ErrorMessage error={command.error} />{removing && <Confirm title="Remove this time block?" description={removing.title} label="Remove block" onCancel={() => setRemoving(null)} pending={command.isPending}
    onConfirm={() => command.mutate({ path: '/schedule/' + removing.id, method: 'DELETE' }, { onSuccess: () => setRemoving(null) })} />}</>;
}
export function ScheduleWidget() {
  const query = useSchedule();
  if (query.isPending) return <Loading />;
  if (query.error) return <ErrorMessage error={query.error} />;
  const blocks = forDay(query.data, dayKey());
  return blocks.length ? <Timeline blocks={blocks.slice(0, 5)} /> : <Empty title="Your day, with a little intention." action={<a className="button secondary" href="#/schedule?new=1"><Plus size={15} /> Plan a time block</a>}>Set aside time for work, learning, or a proper break.</Empty>;
}
export function SchedulePage() {
  const query = useSchedule(), [day, setDay] = useState(dayKey());
  const [editor, setEditor] = useState<Block | null | undefined>(window.location.hash.includes('?') ? null : undefined);
  const blocks = forDay(query.data ?? [], day);
  function shift(n: number) { const date = new Date(day + 'T12:00:00'); date.setDate(date.getDate() + n); setDay(dayKey(date)); }
  return <><PageHeader eyebrow="A LITTLE STRUCTURE. A LOT OF SPACE." title="Planner" description="Give your priorities time. Leave room for everything else."
    action={<button className="button primary" onClick={() => setEditor(null)}><Plus size={17} /> Add time block</button>} />
    <div className="toolbar"><div className="actions"><button className="icon-button" aria-label="Previous day" onClick={() => shift(-1)}><ArrowLeft size={17} /></button>
      <input type="date" aria-label="Selected day" required value={day} onChange={e => e.target.value && setDay(e.target.value)} />
      <button className="icon-button" aria-label="Next day" onClick={() => shift(1)}><ArrowRight size={17} /></button><button className="button secondary" onClick={() => setDay(dayKey())}>Today</button></div>
      <span className="muted">{blocks.length} blocks · {Math.round(blocks.reduce((sum, b) => sum + (Date.parse(b.endAt) - Date.parse(b.startAt)) / 60_000, 0))} min planned</span></div>
    {editor !== undefined && <BlockEditor key={editor?.id ?? day} block={editor} day={day} close={() => setEditor(undefined)} />}
    <div className="panel"><ErrorMessage error={query.error} />{query.isPending ? <Loading /> : blocks.length ? <Timeline blocks={blocks} edit={setEditor} /> : <Empty title="A clear day ahead.">Add your first time block to start shaping it.</Empty>}</div>
  </>;
}
