import { useState, type FormEvent } from 'react';
import { Check, Circle, Plus, Pencil, Trash2, ArrowRight } from 'lucide-react';
import type { Task } from '../../../shared/schema';
import { dayKey, fromDayInput, plannedKey, dateInput, isTaskForDay } from '../../../shared/dates';
import { useCommand } from '../../lib/api';
import { useTasks } from './api';
import { PageHeader, Empty, ErrorMessage, Loading, Badge, Confirm, formatDate } from '../../components/ui';

function TaskEditor({ task, close }: { task: Task | null; close: () => void }) {
  const command = useCommand(['tasks']);
  const [title, setTitle] = useState(task?.title ?? '');
  const [notes, setNotes] = useState(task?.notes ?? '');
  const [planned, setPlanned] = useState(task ? plannedKey(task) ?? '' : dayKey());
  const [due, setDue] = useState(dateInput(task?.dueAt ?? null));
  async function submit(event: FormEvent) {
    event.preventDefault();
    try {
      await command.mutateAsync({ path: task ? '/tasks/' + task.id : '/tasks', method: task ? 'PATCH' : 'POST',
        body: { title, notes: notes || null, plannedDay: fromDayInput(planned), dueAt: due ? new Date(due).toISOString() : null } });
      close();
    } catch { /* Form retains the draft on error. */ }
  }
  return <form className="editor panel" onSubmit={submit}>
    <div className="section-title"><h2>{task ? 'Edit task' : 'A little less on your mind.'}</h2><span className="eyebrow">{task ? 'EDIT' : 'QUICK CAPTURE'}</span></div>
    <label>What needs doing?<input required maxLength={2000} value={title} onChange={e => setTitle(e.target.value)} placeholder="Write it down, then make room for it." /></label>
    <div className="form-grid"><label>Planned day<input type="date" value={planned} onChange={e => setPlanned(e.target.value)} /></label>
      <label>Due date & time <span className="muted">(optional)</span><input type="datetime-local" value={due} onChange={e => setDue(e.target.value)} /></label></div>
    <label>Notes <span className="muted">(optional)</span><textarea rows={3} value={notes} onChange={e => setNotes(e.target.value)} /></label>
    <ErrorMessage error={command.error} />
    <div className="actions"><button className="button primary" disabled={command.isPending}>{command.isPending ? 'Saving…' : 'Save task'}</button><button type="button" className="button secondary" onClick={close} disabled={command.isPending}>Cancel</button></div>
  </form>;
}
function TaskRows({ tasks, edit }: { tasks: Task[]; edit?: (task: Task) => void }) {
  const command = useCommand(['tasks']);
  const [removing, setRemoving] = useState<Task | null>(null);
  return <><ErrorMessage error={command.error} /><ul className="task-list">{tasks.map(task => <li key={task.id} className={task.completedAt ? 'is-complete' : ''}>
    <button className="check-button" aria-label={(task.completedAt ? 'Reopen ' : 'Complete ') + task.title} disabled={command.isPending}
      onClick={() => command.mutate({ path: '/tasks/' + task.id, method: 'PATCH', body: { completedAt: task.completedAt ? null : new Date().toISOString() } })}>
      {task.completedAt ? <Check size={15} /> : <Circle size={18} />}</button>
    <div className="task-copy"><span className="task-title">{task.title}</span>
      {(task.dueAt || task.plannedDay) && <div className="row-meta">{task.plannedDay && <span>Planned {plannedKey(task)}</span>}
        {task.dueAt && <span className={!task.completedAt && Date.parse(task.dueAt) < Date.now() ? 'warning-text' : ''}>Due {formatDate(task.dueAt)}</span>}</div>}
      {edit && task.notes && <p className="task-notes">{task.notes}</p>}</div>
    {edit && <div className="row-actions"><button className="icon-button" onClick={() => edit(task)} aria-label={'Edit ' + task.title}><Pencil size={15} /></button>
      <button className="icon-button" onClick={() => setRemoving(task)} aria-label={'Delete ' + task.title}><Trash2 size={15} /></button></div>}
  </li>)}</ul>{removing && <Confirm title={'Delete “' + removing.title + '”?'} description="This removes the task. Any linked Focus history keeps its saved title." label="Delete task"
    pending={command.isPending} onCancel={() => setRemoving(null)} onConfirm={() => command.mutate({ path: '/tasks/' + removing.id, method: 'DELETE' }, { onSuccess: () => setRemoving(null) })} />}</>;
}
export function TasksWidget() {
  const query = useTasks(), command = useCommand(['tasks']);
  const [title, setTitle] = useState('');
  if (query.isPending) return <Loading />;
  if (query.error) return <ErrorMessage error={query.error} />;
  const today = query.data.filter(t => !t.completedAt && isTaskForDay(t, dayKey()));
  async function capture(event: FormEvent) {
    event.preventDefault();
    try {
      await command.mutateAsync({ path: '/tasks', body: { title, notes: null, plannedDay: fromDayInput(dayKey()), dueAt: null } });
      setTitle('');
    } catch { /* Retain input. */ }
  }
  return <><div className="widget-summary"><strong>{String(today.length).padStart(2, '0')}</strong><span>on your list today</span><Badge>{query.data.filter(t => t.completedAt && dayKey(new Date(t.completedAt)) === dayKey()).length} done</Badge></div>
    {today.length ? <TaskRows tasks={today.slice(0, 5)} /> : <Empty title="Room to think.">Capture a task and give it a place in your day.</Empty>}
    {today.length > 5 && <a className="text-link" href="#/tasks">View {today.length - 5} more <ArrowRight size={14} /></a>}
    <form className="quick-capture" onSubmit={capture}><Plus size={17} /><input aria-label="New task for today" required value={title} onChange={e => setTitle(e.target.value)} placeholder="Add a task for today…" maxLength={2000} />
      <button className="icon-button" aria-label="Add task" disabled={command.isPending || !title.trim()}><ArrowRight size={17} /></button></form><ErrorMessage error={command.error} /></>;
}
export function TasksPage() {
  const query = useTasks();
  const [filter, setFilter] = useState('today'), [search, setSearch] = useState('');
  const [editor, setEditor] = useState<Task | null | undefined>(undefined);
  const tasks = query.data ?? [];
  const filtered = tasks.filter(t => (filter === 'completed' ? !!t.completedAt : !t.completedAt) &&
    (filter !== 'today' || isTaskForDay(t, dayKey())) &&
    (filter !== 'unplanned' || !t.plannedDay) && (t.title + ' ' + (t.notes ?? '')).toLowerCase().includes(search.toLowerCase()));
  return <><PageHeader eyebrow="MAKE ROOM FOR WHAT MATTERS" title="Tasks" description="A clear head starts with a clear list."
    action={<button className="button primary" onClick={() => setEditor(null)}><Plus size={17} /> Add task</button>} />
    {editor !== undefined && <TaskEditor key={editor?.id ?? 'new'} task={editor} close={() => setEditor(undefined)} />}
    <div className="toolbar"><div className="tabs" aria-label="Task filter">{[['today', 'Today'], ['open', 'All open'], ['unplanned', 'Unplanned'], ['completed', 'Completed']].map(([id, name]) =>
      <button key={id} className={filter === id ? 'active' : ''} aria-pressed={filter === id} onClick={() => setFilter(id)}>{name}</button>)}</div>
      <input className="search-input" aria-label="Search tasks" value={search} onChange={e => setSearch(e.target.value)} placeholder="Search tasks…" /></div>
    <div className="panel"><ErrorMessage error={query.error} />{query.isPending ? <Loading /> : filtered.length ? <TaskRows tasks={filtered} edit={setEditor} /> : <Empty title={filter === 'completed' ? 'Every small finish counts.' : 'Nothing here yet.'}>Your tasks will appear here when they match this view.</Empty>}</div>
  </>;
}
