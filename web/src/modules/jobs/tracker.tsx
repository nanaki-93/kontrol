import { useState, type FormEvent } from 'react';
import { Bookmark, Plus } from 'lucide-react';
import { canonicalURL, jobSkillCandidates, relatedLessons, stageLabels, stages, type TrackedJob } from '../../../shared/workspace';
import { dayKey } from '../../../shared/dates';
import { workModeLabels } from '../../../shared/jobs';
import { Badge, Empty, ErrorMessage, Loading, formatDate } from '../../components/ui';
import { useWorkspace, useWorkspaceCommand } from '../workspace/api';
import { useLearning } from '../learning/api';

export function SaveJob({ matchID, url }: { matchID: string; url: string }) {
  const query = useWorkspace(), command = useWorkspaceCommand();
  const saved = query.data?.jobs.find(j => canonicalURL(j.job.url) === canonicalURL(url));
  return <div className="save-job">{saved ? <a className="text-link" href={'#/jobs?view=tracker&job=' + saved.id}><Bookmark size={14} />{stageLabels[saved.stage]} · Open application</a> :
    <button className="button secondary" disabled={!query.data || command.isPending} onClick={() => command.mutate({ path: '/jobs', body: { matchID } })}><Bookmark size={14} />Save opportunity</button>}<ErrorMessage error={command.error ?? query.error} /></div>;
}
function ManualJob({ onClose }: { onClose: () => void }) {
  const command = useWorkspaceCommand();
  const [draft, setDraft] = useState({ title: '', company: '', url: '', location: '', description: '' });
  async function submit(event: FormEvent) {
    event.preventDefault();
    try { await command.mutateAsync({ path: '/jobs', body: { manual: draft } }); onClose(); } catch { /* Keep the entered offer. */ }
  }
  return <form className="panel editor" onSubmit={e => void submit(e)}><h2>Save a job from anywhere</h2>
    <div className="form-grid">{(['title', 'company', 'url', 'location'] as const).map(key => <label key={key}>{({ title: 'Job title', company: 'Company', url: 'Original offer URL', location: 'Location (optional)' })[key]}<input required={key !== 'location'} type={key === 'url' ? 'url' : 'text'} maxLength={key === 'url' ? 4096 : key === 'location' ? 1000 : 200} value={draft[key]} onChange={e => setDraft({ ...draft, [key]: e.target.value })} /></label>)}</div>
    <label>Description or requirements (optional)<textarea rows={5} maxLength={12_000} value={draft.description} onChange={e => setDraft({ ...draft, description: e.target.value })} /></label>
    <p className="footnote">The link and your text are saved locally. No CV or AI connection is needed; this does not fetch or submit an application.</p>
    <ErrorMessage error={command.error} /><div className="actions"><button className="button primary" disabled={command.isPending}>Save opportunity</button><button type="button" className="button secondary" onClick={onClose}>Cancel</button></div>
  </form>;
}
function ApplicationEditor({ record }: { record: TrackedJob }) {
  const command = useWorkspaceCommand(), learning = useLearning();
  const [stage, setStage] = useState(record.stage), [notes, setNotes] = useState(record.notes), [followUpOn, setFollowUp] = useState(record.followUpOn ?? '');
  const [skills, setSkills] = useState(record.skills), [baseline, setBaseline] = useState(record.revision), [saved, setSaved] = useState(false);
  const candidates = jobSkillCandidates(record);
  async function submit(event: FormEvent) {
    event.preventDefault(); setSaved(false);
    try {
      const state = await command.mutateAsync({ path: '/jobs/' + record.id, method: 'PATCH', body: { stage, notes, followUpOn: followUpOn || null, skills, expectedRecordRevision: baseline } });
      setBaseline(state.jobs.find(j => j.id === record.id)!.revision); setSaved(true);
    } catch { /* Keep the application draft. */ }
  }
  return <form className="editor application-editor" onSubmit={e => void submit(e)} onChange={() => setSaved(false)}>
    <div className="form-grid"><label>Application stage<select value={stage} onChange={e => setStage(e.target.value as TrackedJob['stage'])}>{stages.map(s => <option key={s} value={s}>{stageLabels[s]}</option>)}</select></label>
      <label>Follow-up date<input type="date" value={followUpOn} onChange={e => setFollowUp(e.target.value)} /></label></div>
    <label>Application notes<textarea rows={4} maxLength={20_000} value={notes} onChange={e => setNotes(e.target.value)} placeholder="Contacts, interview preparation, and next steps" /></label>
    <div className="skill-bridge"><h3>Turn requirements into practice</h3><p className="footnote">These topics are mentioned in the offer. A missing CV detail is not evidence that you lack a skill. Confirm your experience or choose what you want to practice.</p>
      {candidates.length ? candidates.map(label => {
        const decision = skills.find(s => s.label === label)?.decision ?? 'unconfirmed';
        const lessons = decision === 'practice' && learning.data ? relatedLessons(learning.data, label) : [];
        return <div className="skill-row" key={label}><label>{label}<select value={decision} onChange={e => setSkills([...skills.filter(s => s.label !== label), { label, decision: e.target.value as TrackedJob['skills'][number]['decision'] }])}>
          <option value="unconfirmed">Experience not confirmed</option><option value="experienced">I have this experience</option><option value="practice">I want to practice this</option></select></label>
          {decision === 'practice' && <div className="suggested-lessons">{learning.isPending ? <Loading /> : learning.error ? <ErrorMessage error={learning.error} /> : lessons.length ? lessons.map(lesson => <a className="text-link" href={'#/learning?lesson=' + encodeURIComponent(lesson.id)} key={lesson.id}>{lesson.title} · {lesson.estimatedMinutes} min →</a>) : <p className="footnote">No matching lesson in the current catalog. Keep this topic in your preparation notes.</p>}</div>}
        </div>;
      }) : <p className="muted">No supported learning topics were identified. Add the requirements to your notes and explore the Learning catalog.</p>}
      <p className="footnote">Save your choices before opening a lesson. Completing a lesson records practice, not professional proficiency.</p>
    </div>
    <ErrorMessage error={command.error} /><div className="actions"><button className="button primary" disabled={command.isPending}>Save application</button>{saved && <span className="success-text" role="status">Application saved</span>}
      {command.error && <button type="button" className="button secondary" onClick={() => { setBaseline(record.revision); command.reset(); }}>Keep my draft for the next save</button>}</div>
    {command.error && <details><summary>Review the currently saved application</summary><p>{stageLabels[record.stage]} · Follow-up: {record.followUpOn ?? 'Not set'}</p><p className="prose-text">{record.notes || 'No notes saved'}</p><ul>{record.skills.map(skill => <li key={skill.label}>{skill.label}: {skill.decision === 'practice' ? 'Practice' : skill.decision === 'experienced' ? 'Experienced' : 'Not confirmed'}</li>)}</ul></details>}
  </form>;
}
export function TrackedJobCard({ record, selected, toggle, expanded = false }: { record: TrackedJob; selected?: boolean; toggle?: () => void; expanded?: boolean }) {
  const [open, setOpen] = useState(expanded);
  const overdue = record.followUpOn && record.followUpOn <= dayKey() && !['archived', 'offer'].includes(record.stage);
  return <article className="panel tracked-job" id={'application-' + record.id}><div className="section-title"><div><p className="eyebrow">{record.job.company}</p><h3><a href={record.job.url} target="_blank" rel="noreferrer">{record.job.title} ↗</a></h3><p className="row-meta">{record.job.location || 'Location not provided'} · Saved {formatDate(record.savedAt)}</p></div><Badge tone={overdue ? 'warning' : ''}>{stageLabels[record.stage]}</Badge></div>
    {record.fit && <p className="match-reason">{record.fit.reason}</p>}
    {record.followUpOn && <p className={overdue ? 'warning-text' : 'muted'}>{overdue ? 'Follow up: ' : 'Follow-up: '}{record.followUpOn}</p>}
    <div className="actions"><button className="button secondary" aria-expanded={open} onClick={() => setOpen(!open)}>{open ? 'Close details' : 'Notes, preparation & next steps'}</button>
      {toggle && <label className="checkbox-label"><input type="checkbox" checked={!!selected} onChange={toggle} />Compare</label>}</div>
    {open && <><ApplicationEditor record={record} /><details><summary>Saved offer & history</summary>
      <p className="prose-text">{record.job.description || 'No description was provided.'}</p>{record.fit?.gaps.length ? <><h3>Not evidenced in your profile or needing confirmation</h3><ul>{record.fit.gaps.map(gap => <li key={gap}>{gap}</li>)}</ul></> : null}
      <p className="footnote">Saved snapshot from {record.job.source}. Check the original offer for current availability.</p><ul>{record.history.map((h, i) => <li key={i}>{stageLabels[h.stage]} · {formatDate(h.at)}</li>)}</ul>
    </details></>}
  </article>;
}
function Comparison({ records }: { records: TrackedJob[] }) {
  return <div className="panel comparison"><h2>Compare saved opportunities</h2><div className="table-scroll"><table><thead><tr><th scope="col">Detail</th>{records.map(r => <th scope="col" key={r.id}>{r.job.title}<br />{r.job.company}</th>)}</tr></thead>
    <tbody>{[
      ['Stage', (r: TrackedJob) => stageLabels[r.stage]], ['Location', (r: TrackedJob) => r.job.location || 'Not stated'],
      ['Arrangement', (r: TrackedJob) => r.job.workMode === 'unknown' ? 'Not stated' : workModeLabels[r.job.workMode]],
      ['Salary', (r: TrackedJob) => r.job.salary || 'Not stated'], ['Why it fits', (r: TrackedJob) => r.fit?.reason ?? 'Not assessed'],
      ['Confirm with source', (r: TrackedJob) => r.fit?.gaps.join('; ') || 'No assessment recorded'], ['Follow-up', (r: TrackedJob) => r.followUpOn ?? 'Not set'],
    ].map(([label, value]) => <tr key={String(label)}><th scope="row">{String(label)}</th>{records.map(r => <td key={r.id}>{(value as (r: TrackedJob) => string)(r)}</td>)}</tr>)}</tbody></table></div></div>;
}
export function JobTracker() {
  const query = useWorkspace(), params = new URLSearchParams(window.location.hash.split('?')[1]);
  const [stage, setStage] = useState('all'), [due, setDue] = useState(params.get('due') === '1'), [adding, setAdding] = useState(false), [search, setSearch] = useState('');
  const [selected, setSelected] = useState<string[]>([]);
  const all = query.data?.jobs ?? [], selectedJob = params.get('job');
  const records = all.filter(r => (stage === 'all' || r.stage === stage) && (!due || (r.followUpOn && r.followUpOn <= dayKey() && !['archived', 'offer'].includes(r.stage))) &&
    (r.job.title + ' ' + r.job.company + ' ' + r.notes).toLowerCase().includes(search.toLowerCase())).sort((a, b) => Number(b.id === selectedJob) - Number(a.id === selectedJob) || b.updatedAt.localeCompare(a.updatedAt));
  function toggle(id: string) { setSelected(ids => ids.includes(id) ? ids.filter(i => i !== id) : ids.length < 3 ? [...ids, id] : ids); }
  return <><div className="toolbar"><div className="tabs" aria-label="Application stages">{['all', ...stages].map(s => <button aria-pressed={stage === s} className={stage === s ? 'active' : ''} key={s} onClick={() => setStage(s)}>{s === 'all' ? 'All' : stageLabels[s as TrackedJob['stage']]} · {s === 'all' ? all.length : all.filter(r => r.stage === s).length}</button>)}</div>
      <button className="button secondary" onClick={() => setAdding(!adding)}><Plus size={14} />Add a job link</button></div>
    {adding && <ManualJob onClose={() => setAdding(false)} />}
    <div className="toolbar"><label>Search applications<input type="search" value={search} onChange={e => setSearch(e.target.value)} /></label><label className="checkbox-label"><input type="checkbox" checked={due} onChange={e => setDue(e.target.checked)} />Follow-ups due</label><span className="row-meta">Select up to three offers to compare.</span></div>
    <ErrorMessage error={query.error} />{selected.length > 1 && <Comparison records={all.filter(r => selected.includes(r.id))} />}
    {query.isPending ? <Loading /> : records.length ? records.map(r => <TrackedJobCard key={r.id} record={r} selected={selected.includes(r.id)} toggle={() => toggle(r.id)} expanded={r.id === selectedJob} />) : <div className="panel"><Empty title={all.length ? 'No applications match these filters.' : 'Keep your next opportunity in view.'}>Save a search result or add a job link. Track applications and preparation without losing them when searches refresh.</Empty></div>}
  </>;
}
