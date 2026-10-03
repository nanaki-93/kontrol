import { useEffect, useState } from 'react';
import { Play, Pause, Square, Timer } from 'lucide-react';
import { useCommand } from '../../lib/api';
import { useSettings } from '../settings/api';
import { useFocus } from './api';
import { Badge, Empty, ErrorMessage, Loading, PageHeader, SectionTitle, formatDate } from '../../components/ui';
import { dayKey } from '../../../shared/dates';

function duration(seconds: number): string { return String(Math.floor(seconds / 60)).padStart(2, '0') + ':' + String(Math.floor(seconds % 60)).padStart(2, '0'); }
function FocusTimer({ compact = false }: { compact?: boolean }) {
  const query = useFocus(), settings = useSettings(), command = useCommand(['focus']);
  const [customMinutes, setMinutes] = useState<number | null>(null);
  const [clock, setClock] = useState({ base: 0, sampled: performance.now(), tick: performance.now() });
  useEffect(() => {
    if (query.data) setClock({ base: query.data.serverNow, sampled: performance.now(), tick: performance.now() });
  }, [query.data, query.dataUpdatedAt]);
  useEffect(() => { const interval = setInterval(() => setClock(c => ({ ...c, tick: performance.now() })), 250); return () => clearInterval(interval); }, []);
  const minutes = customMinutes ?? settings.data?.preferences.focusDefaultMinutes ?? 25;
  const active = query.data?.sessions.find(s => ['running', 'paused'].includes(s.state));
  const now = clock.base + clock.tick - clock.sampled;
  const remaining = active ? active.state === 'running' && active.deadline ?
    Math.ceil(Math.min(active.plannedSeconds, Math.max(0, (Date.parse(active.deadline) - now) / 1000))) :
    Math.ceil(active.plannedSeconds - active.accumulatedActiveSeconds) : minutes * 60;
  if (query.isPending) return <Loading />;
  if (query.error) return <ErrorMessage error={query.error} />;
  return <div className={'focus-timer ' + (compact ? 'compact' : '')}>
    <div className="row-spread"><Badge tone={active?.state === 'running' ? 'success' : ''}><span className="status-dot" />{active ? active.state === 'running' ? 'In the zone' : 'On pause' : 'Ready when you are'}</Badge><Timer size={18} className="muted" /></div>
    <div className="timer-digits" role="timer" aria-label={Math.ceil(remaining / 60) + ' minutes remaining'}>{duration(remaining)}</div>
    <p className="timer-caption">{active?.linkedTitleSnapshot ?? (active ? 'One thing at a time.' : 'One small window. Your full attention.')}</p>
    {active?.recoveryRequired && <p className="warning-text">The clock changed while Kontrol was closed. Resume the remaining time or end this session.</p>}
    {active ? <div className="actions centered">
      <button className="button primary" disabled={command.isPending || remaining === 0} onClick={() => command.mutate({ path: '/focus/' + active.id + '/' + (active.state === 'running' ? 'pause' : 'resume') })}>
        {active.state === 'running' ? <Pause size={16} /> : <Play size={16} />}{active.state === 'running' ? 'Pause' : 'Resume'}</button>
      <button className="button secondary" disabled={command.isPending} onClick={() => command.mutate({ path: '/focus/' + active.id + '/end' })}><Square size={14} /> End session</button></div> :
      <><div className="duration-presets">{[15, 25, 50].map(n => <button key={n} className={minutes === n ? 'selected' : ''} aria-pressed={minutes === n} onClick={() => setMinutes(n)}>{n} min</button>)}
        <label className="custom-duration"><span className="sr-only">Custom duration in minutes</span><input type="number" min={1} max={1440} value={minutes} onChange={e => setMinutes(Number(e.target.value))} /><span>min</span></label></div>
        <button className="button primary focus-start" disabled={command.isPending || !Number.isInteger(minutes) || minutes < 1 || minutes > 1440}
          onClick={() => command.mutate({ path: '/focus', body: { minutes } })}><Play size={16} /> Start focusing</button></>}
    <ErrorMessage error={command.error} />
  </div>;
}
export function FocusWidget() { return <FocusTimer compact />; }
export function FocusPage() {
  const query = useFocus();
  const history = [...(query.data?.sessions ?? [])].filter(s => s.endedAt).sort((a, b) => b.endedAt!.localeCompare(a.endedAt!));
  const todayMinutes = Math.floor(history.filter(s => dayKey(new Date(s.endedAt!)) === dayKey()).reduce((sum, s) => sum + s.accumulatedActiveSeconds, 0) / 60);
  return <><PageHeader eyebrow="PROTECT YOUR ATTENTION" title="Focus" description="Less switching. More finishing. Take it one session at a time." />
    <div className="split-grid"><div className="panel"><FocusTimer /></div><div className="panel">
      <SectionTitle meta={<Badge>{todayMinutes} min today</Badge>}>Session history</SectionTitle>
      <p className="muted">A record of the time you’ve given your attention.</p>
      {history.length ? <ul className="simple-list">{history.map(s => <li key={s.id}><div><strong>{s.linkedTitleSnapshot ?? 'Open focus'}</strong><div className="row-meta">{formatDate(s.endedAt!)} · {Math.floor(s.accumulatedActiveSeconds / 60)} min focused</div></div><Badge tone={s.state === 'completed' ? 'success' : ''}>{s.state === 'completed' ? 'Completed' : 'Ended early'}</Badge></li>)}</ul> : <Empty title="Build a little momentum.">Your finished sessions will collect here.</Empty>}
    </div></div>
  </>;
}
