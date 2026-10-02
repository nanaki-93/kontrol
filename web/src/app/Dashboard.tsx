import { Suspense, useEffect, useState } from 'react';
import { ArrowDown, ArrowUp, ArrowUpRight, Check, SlidersHorizontal, RotateCcw, Plus } from 'lucide-react';
import { defaultLayout, type Layout } from '../../shared/schema';
import { dayKey, isTaskForDay } from '../../shared/dates';
import { useCommand } from '../lib/api';
import { useTasks } from '../modules/tasks/api';
import { useFocus } from '../modules/focus/api';
import { useSettings } from '../modules/settings/api';
import { useLearning } from '../modules/learning/api';
import { useProjects } from '../modules/projects/api';
import { ErrorMessage, Loading, Empty, ModuleBoundary, PageHeader } from '../components/ui';
import { modules } from './modules';

function OverviewStats() {
  const tasks = useTasks(), focus = useFocus(), learning = useLearning(), projects = useProjects();
  const today = dayKey();
  const stats = [
    { label: 'TASKS TO DO', value: tasks.data?.filter(t => !t.completedAt && isTaskForDay(t, today)).length, unit: 'for today', route: 'tasks', caption: 'Make a little headway' },
    { label: 'TIME WELL SPENT', value: focus.data && Math.floor(focus.data.sessions.filter(s => s.endedAt && dayKey(new Date(s.endedAt)) === today).reduce((n, s) => n + s.accumulatedActiveSeconds, 0) / 60), unit: 'min today', route: 'focus', caption: 'Give your attention a home' },
    { label: 'SMALL DISCOVERIES', value: learning.data?.progress.filter(p => p.status === 'completed').length, unit: 'lessons finished', route: 'learning', caption: 'Build on what you know' },
    { label: 'PROJECTS CONNECTED', value: projects.data?.length, unit: 'in your workspace', route: 'projects', caption: 'Keep moving things forward' },
  ];
  return <div className="stats-grid">{stats.map((stat, i) => <a href={'#/' + stat.route} className="stat-card" key={stat.label}><div className="row-spread"><span className="eyebrow">{stat.label}</span><span className="stat-index">0{i + 1}</span></div><div className="stat-value">{stat.value === undefined ? '—' : String(stat.value).padStart(2, '0')}<span>{stat.unit}</span></div><p>{stat.caption}<ArrowUpRight size={14} /></p></a>)}</div>;
}
export function Dashboard() {
  const settings = useSettings(), command = useCommand(['settings']);
  const [customizing, setCustomizing] = useState(window.location.hash.includes('customize=1'));
  const [draft, setDraft] = useState<Layout | null>(null);
  const [now, setNow] = useState(new Date());
  useEffect(() => { const timer = setInterval(() => setNow(new Date()), 60_000); return () => clearInterval(timer); }, []);
  const layout = draft ?? settings.data?.layout ?? defaultLayout;
  const date = now.toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' });
  const greeting = now.getHours() < 12 ? 'A little clarity for your morning.' : now.getHours() < 18 ? 'A little clarity for your day.' : 'A little clarity for your evening.';
  function move(index: number, direction: number) {
    const next = [...layout];
    [next[index], next[index + direction]] = [next[index + direction], next[index]];
    setDraft(next);
  }
  async function save() {
    try { await command.mutateAsync({ path: '/settings/layout', method: 'PUT', body: layout }); setCustomizing(false); setDraft(null); history.replaceState(null, '', '#/'); }
    catch { /* Keep layout edits. */ }
  }
  return <><PageHeader eyebrow={date.toUpperCase()} title="Your day, in view." description={greeting}
    action={<button className={'button ' + (customizing ? 'primary' : 'secondary')} onClick={() => { setDraft(null); setCustomizing(!customizing); }}><SlidersHorizontal size={16} />{customizing ? 'Close customization' : 'Customize'}</button>} />
    <OverviewStats />
    <div className="dashboard-divider"><div><span className="eyebrow">YOUR DASHBOARD</span><span className="dashboard-count">{layout.filter(w => w.visible).length} widgets</span></div><span className="row-meta">A space for what matters.</span></div>
    <ErrorMessage error={settings.error} />
    {customizing && <section className="panel layout-editor"><div className="section-title"><h2>Arrange your workspace.</h2><button className="text-link" onClick={() => setDraft(defaultLayout)}><RotateCcw size={14} /> Reset layout</button></div><p className="muted">Show what you need. Change the size. Put your priorities first.</p>
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
    <footer className="dashboard-footer"><span><i className="status-dot" /> LOCAL WORKSPACE</span><span>A little more intentional, every day.</span><span>KONTROL / 0.1</span></footer>
  </>;
}
