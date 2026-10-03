import { Suspense, useEffect, useState } from 'react';
import { ArrowDown, ArrowUp, ArrowUpRight, BookOpen, BriefcaseBusiness, Check, Rss, SlidersHorizontal, RotateCcw, Plus } from 'lucide-react';
import { defaultLayout, type Layout } from '../../shared/schema';
import { dayKey } from '../../shared/dates';
import { canonicalURL, dueReviews, nextLesson, layoutPresets } from '../../shared/workspace';
import { useCommand } from '../lib/api';
import { useSettings } from '../modules/settings/api';
import { useLearning } from '../modules/learning/api';
import { useJobs } from '../modules/jobs/api';
import { useNews, useBriefingStories } from '../modules/news/api';
import { useWorkspace } from '../modules/workspace/api';
import { QuickCapture } from '../modules/workspace/notes';
import { WeeklyReview } from '../modules/workspace/weekly';
import { ErrorMessage, Loading, Empty, ModuleBoundary, PageHeader } from '../components/ui';
import { modules } from './modules';

function TodayActions() {
  const learning = useLearning(), workspace = useWorkspace(), news = useNews(), jobs = useJobs();
  const lesson = learning.data ? nextLesson(learning.data, workspace.data) : undefined;
  const due = learning.data && workspace.data ? dueReviews(learning.data, workspace.data).length : 0;
  const stories = useBriefingStories(news.data, workspace.data);
  const unread = stories.filter(s => !workspace.data?.articles.some(a => canonicalURL(a.article.url) === canonicalURL(s.lead.url) && a.readAt)).length;
  const followups = workspace.data?.jobs.filter(j => j.followUpOn && j.followUpOn <= dayKey() && !['archived', 'offer'].includes(j.stage)) ?? [];
  const matches = jobs.data?.matches.filter(job => (!job.expiresAt || Date.parse(job.expiresAt) > Date.now()) && !workspace.data?.jobs.some(j => canonicalURL(j.job.url) === canonicalURL(job.url))) ?? [];
  const actions = [
    { label: 'LEARNING', icon: BookOpen, detail: lesson ? lesson.estimatedMinutes + ' min · ' + due + ' reviews due' : due + ' reviews due', route: lesson ? 'learning?lesson=' + encodeURIComponent(lesson.id) : 'learning', action: lesson ? 'Continue learning' : 'Choose a learning step', pending: learning.isPending },
    { label: 'NEWS', icon: Rss, detail: stories.length ? stories.length + ' stories · ' + unread + ' unread' : 'Build a briefing around your interests', route: stories.length ? 'news' : 'news?view=discover', action: stories.length ? 'Read your briefing' : 'Find relevant stories', pending: news.isPending },
    { label: 'JOBS', icon: BriefcaseBusiness, detail: followups.length ? followups.length + ' due today or earlier' : matches.length ? matches.length + ' matches to review' : 'Find and save your next role', route: followups.length ? 'jobs?view=tracker&due=1' : 'jobs', action: followups.length ? 'Review follow-ups' : 'Explore opportunities', pending: jobs.isPending },
  ];
  return <><ErrorMessage error={workspace.error ?? learning.error ?? news.error ?? jobs.error} />
    <nav className="today-actions" aria-label="Your next actions">{actions.map(item => <a href={'#/' + item.route} className="today-action" key={item.label}>
      <item.icon className="today-action-icon" size={20} aria-hidden="true" />
      <span className="today-action-copy"><span className="eyebrow">{item.label}</span><strong>{item.action}</strong><span className="today-action-detail">{item.pending || workspace.isPending ? 'Loading your next step…' : item.detail}</span></span>
      <ArrowUpRight className="today-action-arrow" size={16} aria-hidden="true" />
    </a>)}</nav>
  </>;
}
export function Dashboard() {
  const settings = useSettings(), command = useCommand(['settings']);
  const workspace = useWorkspace();
  const [customizing, setCustomizing] = useState(window.location.hash.includes('customize=1'));
  const [draft, setDraft] = useState<Layout | null>(null);
  const [now, setNow] = useState(new Date());
  useEffect(() => { const timer = setInterval(() => setNow(new Date()), 60_000); return () => clearInterval(timer); }, []);
  const layout = draft ?? settings.data?.layout ?? defaultLayout;
  const date = now.toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' });
  const greeting = workspace.data?.profile.goal || 'Learn something useful. Stay informed. Move toward your next opportunity.';
  function move(index: number, direction: number) {
    const next = [...layout];
    [next[index], next[index + direction]] = [next[index + direction], next[index]];
    setDraft(next);
  }
  async function save() {
    try { await command.mutateAsync({ path: '/settings/layout', method: 'PUT', body: layout }); setCustomizing(false); setDraft(null); history.replaceState(null, '', '#/'); }
    catch { /* Keep layout edits. */ }
  }
  return <><PageHeader eyebrow={date.toUpperCase()} title="What matters today." description={greeting}
    action={<button className={'button ' + (customizing ? 'primary' : 'secondary')} onClick={() => { setDraft(null); setCustomizing(!customizing); }}><SlidersHorizontal size={16} />{customizing ? 'Close customization' : 'Customize'}</button>} />
    <TodayActions />
    <div className="dashboard-divider"><div><span className="eyebrow">YOUR DASHBOARD</span><span className="dashboard-count">{layout.filter(w => w.visible).length} widgets</span></div><span className="row-meta">A space for what matters.</span></div>
    <ErrorMessage error={settings.error} />
    {customizing && <section className="panel layout-editor"><div className="section-title"><h2>Arrange your workspace.</h2><button className="text-link" onClick={() => setDraft(defaultLayout)}><RotateCcw size={14} /> Reset layout</button></div><p className="muted">Show what you need. Change the size. Put your priorities first.</p>
      <div className="actions layout-presets"><span className="row-meta">Start with a preset:</span>{(['balanced', 'learning', 'job-search'] as const).map(preset => <button key={preset} className="button secondary" onClick={() => setDraft(structuredClone(layoutPresets[preset]))}>{preset === 'job-search' ? 'Job search' : preset === 'learning' ? 'Learning' : 'Balanced'}</button>)}</div>
      <ol className="layout-list">{layout.map((item, index) => {
        const module = modules.find(m => m.id === item.id)!;
        return <li key={item.id}><label className="checkbox-label"><input type="checkbox" checked={item.visible} onChange={e => setDraft(layout.map(w => w.id === item.id ? { ...w, visible: e.target.checked } : w))} /><module.icon size={17} /><span>{module.title}</span></label>
          <div className="actions"><select aria-label={module.title + ' widget width'} value={item.width} onChange={e => setDraft(layout.map(w => w.id === item.id ? { ...w, width: e.target.value as 'normal' | 'wide' } : w))}><option value="normal">Half width</option><option value="wide">Full width</option></select>
            <button className="icon-button" aria-label={'Move ' + module.title + ' earlier'} disabled={index === 0} onClick={() => move(index, -1)}><ArrowUp size={15} /></button><button className="icon-button" aria-label={'Move ' + module.title + ' later'} disabled={index === layout.length - 1} onClick={() => move(index, 1)}><ArrowDown size={15} /></button></div></li>;
      })}</ol><ErrorMessage error={command.error} /><div className="actions"><button className="button primary" disabled={command.isPending} onClick={() => void save()}><Check size={16} /> Save layout</button><button className="button secondary" disabled={command.isPending} onClick={() => { setDraft(null); setCustomizing(false); }}>Cancel</button></div>
    </section>}
    {settings.isPending ? <Loading /> : <div className="dashboard-grid">{layout.filter(w => w.visible).map(item => {
      const module = modules.find(m => m.id === item.id)!;
      return <section key={item.id} className={'widget widget-' + item.id + (item.width === 'wide' ? ' widget-wide' : '')}>
        <header className="widget-header"><div><module.icon size={17} /><h2>{module.widgetTitle}</h2></div><a className="icon-button" href={'#/' + module.id} aria-label={'Open ' + module.title}><ArrowUpRight size={18} /></a></header>
        <div className="widget-body"><ModuleBoundary><Suspense fallback={<Loading />}><module.widget /></Suspense></ModuleBoundary></div>
      </section>;
    })}</div>}
    {!layout.some(w => w.visible) && <div className="panel"><Empty title="A blank canvas, by choice." action={<button className="button secondary" onClick={() => setCustomizing(true)}><Plus size={16} /> Add widgets</button>}>Bring back a widget whenever you need it. Your data and feature pages are still here.</Empty></div>}
    <div className="today-utilities"><QuickCapture /><section className="panel"><div className="section-title"><h2>Across time zones</h2><a className="text-link" href="#/settings">Edit clocks →</a></div>
      {workspace.data?.profile.timeZones.length ? <div className="world-clocks">{workspace.data.profile.timeZones.map(zone => <div key={zone.label + zone.zone}><span>{zone.label}</span><strong>{now.toLocaleTimeString(undefined, { timeZone: zone.zone, hour: '2-digit', minute: '2-digit' })}</strong><span className="row-meta">{now.toLocaleDateString(undefined, { timeZone: zone.zone, weekday: 'short', month: 'short', day: 'numeric' })}</span></div>)}</div> : <p className="muted">Add clocks for the places where you work or apply in Settings.</p>}
    </section></div>
    <WeeklyReview />
    <footer className="dashboard-footer"><span><i className="status-dot" /> LOCAL WORKSPACE</span><span>A little more intentional, every day.</span><span>KONTROL / 0.1</span></footer>
  </>;
}
