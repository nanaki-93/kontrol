import { useState } from 'react';
import { Bookmark } from 'lucide-react';
import { dueReviews, learningPaths, lessonDefinition, relatedLessons, type WorkspaceProfile } from '../../../shared/workspace';
import type { Learning } from '../../../shared/schema';
import { Badge, Empty, ErrorMessage, Loading, formatDate } from '../../components/ui';
import { useWorkspace, useWorkspaceCommand } from '../workspace/api';
import { NoteEditor } from '../workspace/notes';

export function SaveLesson({ lessonID }: { lessonID: string }) {
  const query = useWorkspace(), command = useWorkspaceCommand(), saved = query.data?.savedLessons.includes(lessonID);
  return <div><button className="text-link" aria-pressed={!!saved} disabled={!query.data || command.isPending} onClick={() => command.mutate({ path: '/lessons/' + encodeURIComponent(lessonID), method: 'PUT', body: { saved: !saved } })}><Bookmark size={14} />{saved ? 'Saved to library' : 'Save lesson'}</button><ErrorMessage error={command.error ?? query.error} /></div>;
}
export function LearningPaths({ state }: { state: Learning }) {
  const query = useWorkspace(), command = useWorkspaceCommand(), [project, setProject] = useState<string | null>(null);
  const completed = new Set(state.progress.filter(p => p.status === 'completed').map(p => p.lessonID));
  function choose(pathID: WorkspaceProfile['pathID']) {
    if (query.data) command.mutate({ path: '/profile', method: 'PUT', body: { profile: { ...query.data.profile, pathID }, expectedProfile: query.data.profile } });
  }
  return <><ErrorMessage error={query.error ?? command.error} /><div className="path-grid">{learningPaths.map(path => {
    const lessons = path.objectives.flatMap(objective => state.definitions.find(d => d.objectiveKey === objective) ?? []);
    const active = query.data?.profile.pathID === path.id;
    return <section className={'panel learning-path' + (active ? ' selected-path' : '')} key={path.id}><div className="section-title"><h2>{path.title}</h2><Badge>{lessons.filter(d => completed.has(d.id)).length} / {lessons.length} practiced</Badge></div>
      <p className="muted">{path.description}</p><ol className="path-lessons">{lessons.map(lesson => <li key={lesson.id}><a href={'#/learning?lesson=' + encodeURIComponent(lesson.id)}>{lesson.title}<span className="row-meta">{completed.has(lesson.id) ? 'Practiced · revisit your work' : lesson.estimatedMinutes + ' min'}</span></a></li>)}</ol>
      {lessons.length < path.objectives.length && <p className="footnote">Some steps are unavailable in this imported catalog.</p>}
      <div className="actions"><button className="button secondary" disabled={!query.data || command.isPending} onClick={() => choose(active ? null : path.id)}>{active ? 'Following · stop following' : 'Follow this path'}</button><button className="text-link" onClick={() => setProject(project === path.id ? null : path.id)}>Apply it in a mini-project</button></div>
      {project === path.id && <div className="practice-project"><h3>Put it into practice</h3><NoteEditor project={{ title: path.title + ' — practice project', body: path.project }} onClose={() => setProject(null)} /></div>}
    </section>;
  })}</div></>;
}
export function ReviewQueue({ state }: { state: Learning }) {
  const query = useWorkspace(), command = useWorkspaceCommand();
  const [selected, setSelected] = useState<string | null>(new URLSearchParams(window.location.hash.split('?')[1]).get('review'));
  const [response, setResponse] = useState(''), [revealed, setRevealed] = useState(false), [message, setMessage] = useState('');
  if (query.isPending) return <Loading />;
  if (!query.data) return <ErrorMessage error={query.error} />;
  const due = dueReviews(state, query.data), id = selected ?? due[0]?.lessonID;
  const lesson = id && state.progress.some(p => p.lessonID === id && p.status === 'completed') ? lessonDefinition(state, id) : undefined;
  async function review(rating: 'again' | 'okay' | 'confident') {
    if (!lesson) return;
    try {
      const result = await command.mutateAsync({ path: '/reviews/' + encodeURIComponent(lesson.id), body: { rating, response } });
      setMessage('Review saved. Next review: ' + formatDate(result.reviews.find(r => r.lessonID === lesson.id)!.nextAt) + '.');
      setSelected(null); setResponse(''); setRevealed(false);
    } catch { /* Keep recall answer until the review is saved. */ }
  }
  return <><div className="panel"><div className="section-title"><h2>Practice remembering</h2><Badge>{due.length} reviews due</Badge></div>
    <p className="muted">Recall the idea in your own words, compare with the reference, then choose when to revisit it. Your original answer and completion stay unchanged.</p>
    {message && <p className="success-text" role="status">{message}</p>}
    <ErrorMessage error={query.error ?? command.error} />
    {lesson ? <div className="review-exercise"><h3>{lesson.title}</h3><p className="prose-text">{lesson.exercise}</p>
      <label>Your recall response<textarea rows={5} maxLength={20_000} value={response} onChange={e => setResponse(e.target.value)} /></label>
      {!revealed ? <button className="button secondary" disabled={!response.trim()} onClick={() => setRevealed(true)}>Compare with reference</button> : <><pre className="lesson-code">{lesson.referenceAnswer}</pre><ul>{lesson.selfCheckCriteria.map(item => <li key={item}>{item}</li>)}</ul>
        <p className="footnote">How did recall feel? This is your self-assessment, not a score.</p><div className="actions">{(['again', 'okay', 'confident'] as const).map(rating => <button className="button secondary" key={rating} disabled={!response.trim() || command.isPending} onClick={() => void review(rating)}>{({ again: 'Review tomorrow', okay: 'Review in 3 days', confident: 'Confident · space it out' })[rating]}</button>)}</div></>}
    </div> : <Empty title="You’re up to date.">Completed lessons enter the review queue after one day. You can revisit any completed lesson from History.</Empty>}
  </div>{due.length > 1 && <div className="panel"><h3>Coming up</h3><ul className="simple-list">{due.filter(r => r.lessonID !== id).map(r => <li key={r.lessonID}><span>{lessonDefinition(state, r.lessonID)?.title}</span><span className="row-meta">Due {formatDate(r.dueAt)}</span></li>)}</ul></div>}</>;
}
export function ExploreLessons({ state, query }: { state: Learning; query: string }) {
  const lessons = relatedLessons(state, query);
  return <div className="panel"><p className="eyebrow">FROM YOUR WORKSPACE</p><h2>Explore: {query}</h2>
    <p className="muted">Suggestions from the existing catalog based on matching topics and lesson descriptions.</p>
    {lessons.length ? <ul className="simple-list">{lessons.map(lesson => <li key={lesson.id}><a className="text-link" href={'#/learning?lesson=' + encodeURIComponent(lesson.id)}>{lesson.title} →</a><Badge>{lesson.estimatedMinutes} min</Badge></li>)}</ul> : <Empty title="No matching lessons yet.">This topic is not covered by the current catalog. Save a note or choose a different learning path.</Empty>}
  </div>;
}
