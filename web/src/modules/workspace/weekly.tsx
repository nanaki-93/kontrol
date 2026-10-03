import { dayKey } from '../../../shared/dates';
import { dueReviews, lessonDefinition, stageLabels } from '../../../shared/workspace';
import { Badge, ErrorMessage } from '../../components/ui';
import { useLearning } from '../learning/api';
import { useWorkspace } from './api';

export function WeeklyReview() {
  const workspace = useWorkspace(), learning = useLearning();
  if (!workspace.data || !learning.data) return <ErrorMessage error={workspace.error ?? learning.error} />;
  const state = workspace.data, now = new Date(), start = new Date(now);
  start.setDate(start.getDate() - (start.getDay() + 6) % 7); start.setHours(0, 0, 0, 0);
  const thisWeek = (at: string) => Date.parse(at) >= start.getTime() && Date.parse(at) <= now.getTime();
  const practiced = learning.data.progress.filter(p => p.completedAt && thisWeek(p.completedAt));
  const reviews = state.reviews.flatMap(r => r.history).filter(h => thisWeek(h.at));
  const reading = state.articles.filter(a => a.savedAt && thisWeek(a.savedAt));
  const moves = state.jobs.flatMap(j => j.history.filter(h => h.stage !== 'saved' && thisWeek(h.at)).map(h => ({ job: j, ...h }))).sort((a, b) => b.at.localeCompare(a.at));
  const due = dueReviews(learning.data, state).length;
  const followups = state.jobs.filter(j => j.followUpOn && j.followUpOn <= dayKey() && !['archived', 'offer'].includes(j.stage)).length;
  return <section className="panel weekly-review"><div className="section-title"><div><p className="eyebrow">WEEK OF {start.toLocaleDateString(undefined, { month: 'short', day: 'numeric' }).toUpperCase()}</p><h2>Your weekly review</h2></div><a className="text-link" href="#/settings">Edit goals →</a></div>
    <div className="weekly-metrics"><div><strong>{practiced.length} / {state.profile.weeklyTarget}</strong><span>lessons practiced</span></div><div><strong>{reviews.length}</strong><span>recall reviews</span></div><div><strong>{reading.length}</strong><span>stories saved</span></div><div><strong>{moves.length}</strong><span>application stage changes</span></div></div>
    <progress className="weekly-progress" aria-label="Weekly lesson target" max={state.profile.weeklyTarget} value={Math.min(practiced.length, state.profile.weeklyTarget)} />
    <div className="weekly-details">{practiced.length > 0 && <div><h3>What you practiced</h3><ul>{practiced.slice(-4).map(p => <li key={p.lessonID}>{lessonDefinition(learning.data!, p.lessonID)?.title ?? p.lessonID}</li>)}</ul></div>}
      {reading.length > 0 && <div><h3>Reading to return to</h3><ul>{reading.slice(-3).map(a => <li key={a.id}><a href="#/news?view=saved">{a.article.title}</a></li>)}</ul></div>}
      {moves.length > 0 && <div><h3>Applications in motion</h3><ul>{moves.slice(0, 4).map((move, i) => <li key={i}><a href={'#/jobs?view=tracker&job=' + move.job.id}>{move.job.job.company} · {stageLabels[move.stage]}</a></li>)}</ul></div>}</div>
    <div className="actions"><Badge>{practiced.length >= state.profile.weeklyTarget ? 'Weekly learning target reached' : (state.profile.weeklyTarget - practiced.length) + ' lessons to your weekly target'}</Badge>
      <a className="text-link" href={due ? '#/learning?view=reviews' : '#/learning'}>{due ? 'Review ' + due + ' lessons' : 'Continue learning'} →</a>
      {followups > 0 && <a className="text-link" href="#/jobs?view=tracker&due=1">{followups} application follow-ups →</a>}
    </div>
  </section>;
}
