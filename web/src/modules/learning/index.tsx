import { useEffect, useRef, useState } from 'react';
import { ArrowLeft, ArrowRight, BookOpen, Check, Eye, CalendarPlus } from 'lucide-react';
import { useQueryClient } from '@tanstack/react-query';
import type { Learning, Attempt, Definition } from '../../../shared/schema';
import { api, useCommand, navigate } from '../../lib/api';
import { useLearning } from './api';
import { useSettings } from '../settings/api';
import { PageHeader, Empty, ErrorMessage, Loading, Badge, SectionTitle, formatDate } from '../../components/ui';

function LessonCard({ lesson, onOpen, status }: { lesson: Definition; onOpen: () => void; status?: string }) {
  return <button className="lesson-card" onClick={onOpen}><div className="row-spread"><Badge>{lesson.format}</Badge><span className="row-meta">{lesson.estimatedMinutes} min</span></div>
    <h3>{lesson.title}</h3><p>{lesson.objective || lesson.objectiveKey}</p><div className="lesson-card-footer"><span>{status === 'started' ? 'Continue lesson' : 'Make a little progress'}</span><ArrowRight size={16} /></div></button>;
}
export function LearningWidget() {
  const query = useLearning();
  if (query.isPending) return <Loading />;
  if (query.error) return <ErrorMessage error={query.error} />;
  const state = query.data;
  const first = state.slots.find(s => state.progress.some(p => p.lessonID === s.lessonID && p.status === 'started')) ?? state.slots[0];
  const lesson = first && (state.attempts.find(a => a.lessonID === first.lessonID && !a.completedAt)?.pinnedContent?.definition ?? state.definitions.find(d => d.id === first.lessonID));
  const completed = state.progress.filter(p => p.status === 'completed').length;
  return <><div className="learning-intro"><BookOpen size={20} /><span>{state.topics.length} paths to explore<span className="muted"> · {completed} lessons completed</span></span></div>
    {lesson ? <LessonCard lesson={lesson} status={state.progress.find(p => p.lessonID === lesson.id)?.status} onOpen={() => navigate('/learning?lesson=' + encodeURIComponent(lesson.id))} /> :
      <Empty title="You have explored your available choices.">Open Learning to review your history or restore a dismissed lesson.</Empty>}</>;
}

// A small local draft survives route changes and failed network saves. Revision
// checks prevent another tab from silently replacing a saved response.
function useAnswer(lessonID: string, attempt: Attempt | undefined) {
  const settings = useSettings(), client = useQueryClient();
  const key = settings.data ? 'kontrol.answer.' + settings.data.instanceID + '.' + lessonID : null;
  const [answer, setAnswer] = useState<string | null>(null), [error, setError] = useState<Error | null>(null);
  const [latest, setLatest] = useState<Attempt | null>(null);
  const [status, setStatus] = useState('Saved');
  const state = useRef({ text: '', saved: '', revision: 0, ready: false, pending: null as Promise<void> | null });
  useEffect(() => {
    if (!attempt || !key || state.current.ready) return;
    let draft: { text: string; revision: number } | null = null;
    try { const raw = localStorage.getItem(key); if (raw) draft = JSON.parse(raw); } catch { /* Server answer remains available. */ }
    state.current = { text: draft?.text ?? attempt.answerDraft, saved: attempt.answerDraft,
      revision: draft?.revision ?? attempt.revision, ready: true, pending: null };
    setAnswer(state.current.text);
    if (state.current.text !== state.current.saved) setStatus('Unsaved draft');
  }, [attempt, key]);
  function edit(text: string) {
    if (!key) return;
    state.current.text = text; setAnswer(text); setStatus('Unsaved draft');
    try { localStorage.setItem(key, JSON.stringify({ text, revision: state.current.revision })); }
    catch { setError(new Error('Browser draft storage is unavailable. Keep this page open until your answer saves.')); }
  }
  async function save(): Promise<void> {
    const s = state.current;
    if (!s.ready || !key) return;
    if (s.pending) { await s.pending; if (s.text !== s.saved) await save(); return; }
    if (s.text === s.saved) return;
    const submitted = s.text;
    setStatus('Saving…');
    s.pending = (async () => {
      try {
        const result = await api<Attempt>('/learning/' + encodeURIComponent(lessonID) + '/answer', 'PATCH', { answer: submitted, revision: s.revision });
        s.saved = submitted; s.revision = result.revision; setError(null);
        if (s.text === submitted) {
          try { localStorage.removeItem(key); } catch { /* The server save succeeded. */ }
          setStatus('Saved');
        } else {
          try { localStorage.setItem(key, JSON.stringify({ text: s.text, revision: s.revision })); } catch { /* The visible draft remains in memory. */ }
          setStatus('Unsaved draft');
        }
        await client.invalidateQueries({ queryKey: ['learning'] });
      } catch (error) { setError(error as Error); setStatus('Not saved'); throw error; }
      finally { s.pending = null; }
    })();
    await s.pending;
  }
  useEffect(() => {
    if (answer === null || answer === state.current.saved) return;
    const timeout = setTimeout(() => { void save().catch(() => {}); }, 700);
    return () => clearTimeout(timeout);
  }, [answer]);
  useEffect(() => () => { void save().catch(() => {}); }, [key]);
  async function reviewSaved() {
    try {
      const current = await api<Learning>('/learning');
      const found = current.attempts.find(a => a.lessonID === lessonID && !a.completedAt);
      if (!found) throw new Error('This lesson has moved to history. Copy your local draft before opening its saved history.');
      setLatest(found);
    } catch (error) { setError(error as Error); }
  }
  async function resolveDraft(keepLocal: boolean) {
    if (!latest || !key) return;
    state.current.saved = latest.answerDraft; state.current.revision = latest.revision;
    if (!keepLocal) {
      state.current.text = latest.answerDraft; setAnswer(latest.answerDraft); setStatus('Saved');
      try { localStorage.removeItem(key); } catch { /* Server text remains available. */ }
    }
    setLatest(null); setError(null);
    if (keepLocal) await save();
  }
  return { answer, edit, save, error: error ?? settings.error, status, latest, reviewSaved, resolveDraft };
}
function LessonWorkspace({ lessonID, state, close }: { lessonID: string; state: Learning; close: () => void }) {
  const command = useCommand<Attempt>(['learning']), action = useCommand(['learning']);
  const [acknowledged, setAcknowledged] = useState(false);
  const progress = state.progress.find(p => p.lessonID === lessonID);
  const historical = progress?.status === 'completed' || progress?.status === 'dismissed';
  const attempts = state.attempts.filter(a => a.lessonID === lessonID);
  const attempt = progress?.status === 'completed' ? attempts.filter(a => a.completedAt).sort((a, b) => b.completedAt!.localeCompare(a.completedAt!))[0] :
    attempts.find(a => !a.completedAt);
  const definition = attempt?.pinnedContent?.definition ??
    state.terminalRecords.find(t => t.lessonID === lessonID)?.dismissalTimeDefinition ??
    (!historical && !attempt ? state.definitions.find(d => d.id === lessonID) : undefined);
  const content = definition ?? attempt?.completedContentSnapshot;
  const draft = useAnswer(lessonID, historical ? undefined : attempt);
  useEffect(() => {
    if (!historical) command.mutate({ path: '/learning/' + encodeURIComponent(lessonID) + '/open' });
  }, [lessonID]);
  async function perform(name: string) {
    try {
      await draft.save();
      await action.mutateAsync({ path: '/learning/' + encodeURIComponent(lessonID) + '/' + name, body: name === 'complete' ? { acknowledged } : {} });
      if (['complete', 'dismiss', 'restore'].includes(name)) close();
    } catch { /* Keep draft and show the mutation error. */ }
  }
  if (!content) return <div className="panel"><button className="button secondary" onClick={close}><ArrowLeft size={16} /> Back</button><ErrorMessage error={command.error ?? action.error} />
    <Empty title={historical || attempt ? 'This legacy record has no saved lesson content.' : 'Opening your lesson…'}>{historical || attempt ? 'Its saved response and history remain preserved. The current definition is not substituted for what you studied.' : 'Your answer will load with its saved lesson version.'}</Empty>
    {attempt && <><h2>Your saved response</h2><pre className="saved-answer">{attempt.answerDraft || 'No response was saved.'}</pre></>}
    {progress?.status === 'dismissed' && <button className="button secondary" disabled={action.isPending} onClick={() => void perform('restore')}>Restore lesson</button>}
  </div>;
  const revealed = !!attempt?.solutionRevealedAt || progress?.status === 'completed';
  return <div className="lesson-workspace"><div className="toolbar"><button className="button secondary" onClick={async () => { try { await draft.save(); close(); } catch { /* Keep current page. */ } }}><ArrowLeft size={16} /> All lessons</button>
    <div className="actions"><Badge>{content.format}</Badge><Badge>{content.difficulty}</Badge>{historical && <Badge tone="success">{progress?.status}</Badge>}</div></div>
    <div className="panel lesson-content"><p className="eyebrow">{definition?.topicID ?? 'YOUR LEARNING HISTORY'}{definition && ' / ' + definition.estimatedMinutes + ' MIN'}</p><h1>{content.title}</h1>
      <section><h2>The idea</h2><div className="prose-text">{content.explanation}</div></section>
      <section><h2>A worked example</h2><pre className="lesson-code">{content.workedExample}</pre></section>
      <section><h2>Your turn</h2><div className="prose-text">{content.exercise}</div></section>
      {historical ? <section><h2>Your saved response</h2><pre className="saved-answer">{attempt?.answerDraft || 'No response was saved.'}</pre></section> :
        <section><div className="row-spread"><h2>Your response</h2><span className="row-meta" role="status">{draft.status}</span></div>
          <textarea className="answer-input" aria-label="Your lesson response" rows={9} value={draft.answer ?? ''} disabled={draft.answer === null} onChange={e => draft.edit(e.target.value)} placeholder="Think it through. This is a space to practice." />
          <ErrorMessage error={draft.error} /><div className="actions"><button className="button secondary" onClick={() => { void draft.save().catch(() => {}); }}>Save response</button>
            {draft.error && <button className="button secondary" onClick={() => void draft.reviewSaved()}>Review saved response</button>}</div>
          {draft.latest && <div className="confirmation"><h3>Currently saved on this Mac</h3><pre className="saved-answer">{draft.latest.answerDraft || 'Empty response'}</pre>
            <p>Your local draft is still in the editor above. Choose which response to keep.</p><div className="actions">
              <button className="button primary" onClick={() => void draft.resolveDraft(true).catch(() => {})}>Save my draft instead</button>
              <button className="button secondary" onClick={() => void draft.resolveDraft(false)}>Use saved response</button></div></div>}</section>}
      {revealed ? <section className="solution"><div className="eyebrow">REFERENCE SOLUTION</div><pre className="lesson-code">{content.referenceAnswer}</pre>
        <h3>Self-check</h3><ul>{content.selfCheckCriteria.map((criterion, i) => <li key={i}>{criterion}</li>)}</ul>
        {!historical && <label className="checkbox-label"><input type="checkbox" checked={acknowledged} onChange={e => setAcknowledged(e.target.checked)} /> I have compared my response with the reference and reviewed the criteria.</label>}</section> :
        !historical && <button className="button secondary" onClick={() => void perform('reveal')} disabled={action.isPending || draft.answer === null}><Eye size={16} /> Reveal solution</button>}
      <ErrorMessage error={command.error ?? action.error} />
      <div className="lesson-bottom"><div className="actions">{!historical && <>
        <button className="button primary" disabled={!revealed || !acknowledged || action.isPending} onClick={() => void perform('complete')}><Check size={16} /> Complete lesson</button>
        <button className="button secondary" disabled={action.isPending || draft.answer === null} onClick={() => void perform('dismiss')}>Dismiss for now</button></>}
        {progress?.status === 'dismissed' && <button className="button primary" disabled={action.isPending} onClick={() => void perform('restore')}>Restore lesson</button>}</div>
        {definition && <a className="text-link" href={'#/schedule?lesson=' + encodeURIComponent(lessonID) + '&title=' + encodeURIComponent(content.title)}><CalendarPlus size={16} /> Add to planner</a>}</div>
      <p className="footnote">Completion records your own practice. It is not an assessment score.</p>
    </div></div>;
}
export function LearningPage() {
  const query = useLearning();
  const [topic, setTopic] = useState('go'), [tab, setTab] = useState('choices');
  const [selected, setSelected] = useState<string | null>(new URLSearchParams(window.location.hash.split('?')[1]).get('lesson'));
  if (query.isPending) return <Loading />;
  if (query.error) return <ErrorMessage error={query.error} />;
  const state = query.data, currentTopic = state.topics.find(t => t.id === topic) ?? state.topics[0];
  if (selected) return <LessonWorkspace key={selected} lessonID={selected} state={state} close={() => { setSelected(null); history.replaceState(null, '', '#/learning'); }} />;
  const topicID = currentTopic?.id;
  const choices = state.slots.filter(s => s.topicID === topicID).sort((a, b) => a.slotIndex - b.slotIndex).flatMap(slot => {
    const lesson = state.attempts.find(a => a.lessonID === slot.lessonID && !a.completedAt)?.pinnedContent?.definition ?? state.definitions.find(d => d.id === slot.lessonID);
    return lesson ? [lesson] : [];
  });
  const historyItems = state.progress.filter(p => ['completed', 'dismissed'].includes(p.status)).filter(p => {
    const d = state.attempts.find(a => a.lessonID === p.lessonID)?.pinnedContent?.definition ?? state.definitions.find(d => d.id === p.lessonID);
    return !d || d.topicID === topicID;
  }).sort((a, b) => (b.completedAt ?? b.dismissedAt ?? '').localeCompare(a.completedAt ?? a.dismissedAt ?? ''));
  const subtopics = new Set(state.subtopics.filter(s => s.topicID === topicID).map(s => s.id));
  const concepts = state.concepts.filter(c => subtopics.has(c.subtopicID));
  const practiced = new Set(state.attempts.filter(a => a.completedAt).flatMap(a => a.pinnedContent?.definition.conceptIDs ?? a.completedContentSnapshot?.conceptIDs ?? [])
    .concat(state.terminalRecords.filter(t => state.progress.some(p => p.lessonID === t.lessonID && p.status === 'completed')).flatMap(t => t.conceptIDs ?? [])));
  const covered = concepts.filter(c => practiced.has(c.id)).length;
  return <><PageHeader eyebrow="STAY CURIOUS" title="Learning" description="Small lessons. Useful ideas. Progress at your pace." action={<Badge tone="success">Available offline</Badge>} />
    <div className="toolbar"><div className="tabs" aria-label="Learning topic">{state.topics.map(t => <button key={t.id} className={t.id === topicID ? 'active' : ''} aria-pressed={t.id === topicID} onClick={() => setTopic(t.id)}>{t.name}</button>)}</div></div>
    <div className="coverage-panel"><div><p className="eyebrow">CONCEPT COVERAGE</p><h2>{covered}<span className="muted"> / {concepts.length}</span></h2><p>Distinct concepts practiced · not a mastery score</p></div>
      <div className="coverage-track"><div style={{ width: (concepts.length ? covered / concepts.length * 100 : 0) + '%' }} /></div><BookOpen size={35} strokeWidth={1} /></div>
    <div className="toolbar"><div className="tabs"><button className={tab === 'choices' ? 'active' : ''} onClick={() => setTab('choices')}>Your next lessons</button><button className={tab === 'history' ? 'active' : ''} onClick={() => setTab('history')}>History</button><button className={tab === 'concepts' ? 'active' : ''} onClick={() => setTab('concepts')}>Concepts</button></div></div>
    {tab === 'choices' && <><div className="lesson-grid">{choices.map(lesson => <LessonCard key={lesson.id} lesson={lesson} onOpen={() => setSelected(lesson.id)} status={state.progress.find(p => p.lessonID === lesson.id)?.status} />)}</div>
      {!choices.length && <div className="panel"><Empty title="No eligible lessons right now.">Review your history or restore a dismissed lesson. Completed lessons are never repeated just to fill a slot.</Empty></div>}</>}
    {tab === 'history' && <div className="panel"><SectionTitle>Saved practice</SectionTitle>{historyItems.length ? <ul className="simple-list">{historyItems.map(p => {
      const attempt = state.attempts.find(a => a.lessonID === p.lessonID);
      const title = attempt?.pinnedContent?.definition.title ?? attempt?.completedContentSnapshot?.title ?? state.terminalRecords.find(t => t.lessonID === p.lessonID)?.title ?? p.lessonID;
      return <li key={p.lessonID}><button className="list-link" onClick={() => setSelected(p.lessonID)}><strong>{title}</strong><span className="row-meta">{formatDate(p.completedAt ?? p.dismissedAt!)} · Open saved work</span></button><Badge tone={p.status === 'completed' ? 'success' : ''}>{p.status}</Badge></li>;
    })}</ul> : <Empty title="Your practice will live here.">Completed and dismissed lessons stay in your history.</Empty>}</div>}
    {tab === 'concepts' && <div className="panel"><ul className="simple-list">{concepts.map(c => <li key={c.id}><span>{c.name}</span><Badge tone={practiced.has(c.id) ? 'success' : ''}>{practiced.has(c.id) ? 'Practiced' : 'Not yet practiced'}</Badge></li>)}</ul></div>}
  </>;
}
