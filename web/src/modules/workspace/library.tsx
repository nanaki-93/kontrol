import { useState } from 'react';
import { lessonDefinition, stageLabels } from '../../../shared/workspace';
import { PageHeader, Empty, Loading, ErrorMessage, Badge } from '../../components/ui';
import { useLearning } from '../learning/api';
import { ArticleList } from '../news/articles';
import { useWorkspace } from './api';
import { NoteCard, NoteEditor } from './notes';
import { SaveLesson } from '../learning/journey';

export function LibraryPage() {
  const query = useWorkspace(), learning = useLearning(), [search, setSearch] = useState(''), [kind, setKind] = useState('all'), [adding, setAdding] = useState(false);
  if (query.isPending) return <Loading />;
  if (!query.data) return <ErrorMessage error={query.error} />;
  const state = query.data, match = (text: string) => text.toLowerCase().includes(search.toLowerCase());
  const articles = ['all', 'reading'].includes(kind) ? state.articles.filter(a => (a.savedAt || a.notes.trim()) && match(a.article.title + ' ' + a.article.summary + ' ' + a.notes)) : [];
  const jobs = ['all', 'jobs'].includes(kind) ? state.jobs.filter(j => match(j.job.title + ' ' + j.job.company + ' ' + j.job.description + ' ' + j.notes)) : [];
  const lessons = learning.data && ['all', 'lessons'].includes(kind) ? state.savedLessons.flatMap(id => {
    const definition = lessonDefinition(learning.data, id), attempt = learning.data.attempts.find(a => a.lessonID === id);
    const title = definition?.title ?? attempt?.completedContentSnapshot?.title ?? learning.data.terminalRecords.find(t => t.lessonID === id)?.title ?? id;
    const explanation = definition?.explanation ?? attempt?.completedContentSnapshot?.explanation ?? 'Historical content unavailable';
    return match(title + ' ' + explanation) ? [{ id, title }] : [];
  }) : [];
  const notes = state.notes.filter(n => (kind === 'all' || kind === 'notes' || n.kind === kind) && match(n.title + ' ' + n.body + ' ' + (n.url ?? '')));
  const count = articles.length + jobs.length + lessons.length + notes.length;
  return <><PageHeader eyebrow="KEEP WHAT MATTERS" title="Saved library" description="Reading, lessons, opportunities, and your own notes in one searchable place."
    action={<button className="button secondary" onClick={() => setAdding(!adding)}>{adding ? 'Close editor' : 'Add note or link'}</button>} />
    {adding && <div className="panel"><NoteEditor onClose={() => setAdding(false)} /></div>}
    <div className="toolbar"><label className="library-search">Search your library<input type="search" value={search} onChange={e => setSearch(e.target.value)} placeholder="Search titles, notes, descriptions…" /></label><Badge>{count} results</Badge></div>
    <div className="tabs library-tabs">{['all', 'reading', 'lessons', 'jobs', 'notes', 'link', 'project'].map(tab => <button key={tab} className={kind === tab ? 'active' : ''} aria-pressed={kind === tab} onClick={() => setKind(tab)}>{tab === 'link' ? 'Pinned links' : tab === 'project' ? 'Practice projects' : tab}</button>)}</div>
    <ErrorMessage error={query.error ?? learning.error} />
    {articles.length > 0 && <section className="panel"><h2>Saved reading</h2>{articles.map(a => <div key={a.id}><ArticleList articles={[a.article]} />{a.notes && <p className="prose-text reading-note-excerpt">Your notes: {a.notes}</p>}</div>)}</section>}
    {lessons.length > 0 && <section className="panel"><h2>Saved lessons</h2><ul className="simple-list">{lessons.map(lesson => <li key={lesson.id}><a className="text-link" href={'#/learning?lesson=' + encodeURIComponent(lesson.id)}>{lesson.title} →</a><SaveLesson lessonID={lesson.id} /></li>)}</ul></section>}
    {jobs.length > 0 && <section className="panel"><h2>Opportunities</h2><ul className="simple-list">{jobs.map(j => <li key={j.id}><a className="list-link" href={'#/jobs?view=tracker&job=' + j.id}><strong>{j.job.title}</strong><span className="row-meta">{j.job.company} · Open application</span></a><Badge>{stageLabels[j.stage]}</Badge></li>)}</ul></section>}
    {notes.map(note => <NoteCard key={note.id} note={note} />)}
    {!count && <div className="panel"><Empty title={search ? 'No saved items match this search.' : 'A home for things worth keeping.'}>Save a story, lesson, or opportunity, or capture your first note.</Empty></div>}
  </>;
}
