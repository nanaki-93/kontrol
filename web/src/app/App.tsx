import { lazy, Suspense, useEffect, useState } from 'react';
import { LayoutDashboard, Settings2, ArrowUpRight, Command } from 'lucide-react';
import { Dashboard } from './Dashboard';
import { modules } from './modules';
import { useSettings } from '../modules/settings/api';
import { useFocus } from '../modules/focus/api';
import { Loading, ModuleBoundary } from '../components/ui';

const SettingsPage = lazy(() => import('../modules/settings').then(m => ({ default: m.SettingsPage })));
export function App() {
  const [hash, setHash] = useState(window.location.hash || '#/');
  const settings = useSettings(), focus = useFocus();
  useEffect(() => {
    const onHash = () => setHash(window.location.hash || '#/');
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  }, []);
  const route = hash.replace(/^#\/?/, '').split('?')[0];
  const module = modules.find(m => m.id === route);
  const active = focus.data?.sessions.find(s => ['running', 'paused'].includes(s.state));
  useEffect(() => { document.title = 'Kontrol — ' + (module?.title ?? (route === 'settings' ? 'Settings' : 'Your dashboard')); }, [route, module]);
  return <div className={'app-shell ' + (settings.data?.preferences.textSize === 'large' ? 'large-text ' : '') + (settings.data?.preferences.reduceMotion === 'reduce' ? 'reduce-motion' : '')}>
    <a className="skip-link" href="#main-content" onClick={event => { event.preventDefault(); document.getElementById('main-content')?.focus(); }}>Skip to content</a>
    <aside className="sidebar"><a className="brand" href="#/" aria-label="Kontrol dashboard"><span className="brand-mark" aria-hidden="true">k<span>↗</span></span><span>kontrol<span className="brand-period">.</span></span></a>
      <div className="workspace-label"><span className="status-dot" /><span>Personal workspace</span></div>
      <nav aria-label="Main navigation"><p className="nav-label">WORKSPACE</p><a href="#/" className={!route ? 'active' : ''} aria-current={!route ? 'page' : undefined}><LayoutDashboard size={18} /><span>Overview</span><span className="nav-tick">↗</span></a>
        <p className="nav-label module-label">YOUR MODULES</p>{modules.map(m => <a href={'#/' + m.id} key={m.id} className={route === m.id ? 'active' : ''} aria-current={route === m.id ? 'page' : undefined}><m.icon size={18} /><span>{m.title}</span>{m.id === 'focus' && active && <i className="status-dot" />}</a>)}
      </nav><div className="sidebar-bottom">{active && <a className="active-session" href="#/focus"><span className="eyebrow">FOCUS {active.state === 'paused' ? 'PAUSED' : 'IN PROGRESS'}</span><strong>{active.linkedTitleSnapshot ?? 'A little room to focus.'}</strong><span>Return to your session <ArrowUpRight size={14} /></span></a>}
        <a className={'settings-nav ' + (route === 'settings' ? 'active' : '')} href="#/settings" aria-current={route === 'settings' ? 'page' : undefined}><Settings2 size={18} /> Settings</a>
        <div className="local-status"><span className={'status-dot ' + (settings.error ? 'offline' : '')} /><span>{settings.error ? 'Server unavailable' : 'On this Mac'}</span><Command size={13} /></div></div>
    </aside>
    <div className="main-shell"><div className="topbar"><div><span className="breadcrumb-brand">Workspace</span><span className="breadcrumb-slash">/</span><strong>{module?.title ?? (route === 'settings' ? 'Settings' : 'Overview')}</strong></div><span className="topbar-note"><span className="status-dot" /> LOCAL FIRST</span></div>
      <main id="main-content" tabIndex={-1}><ModuleBoundary key={hash}><Suspense fallback={<Loading />}>
        {!route ? <Dashboard key={hash} /> : route === 'settings' ? <SettingsPage /> : module ? <module.page key={hash} /> :
          <div className="panel empty"><h1>This page is not in your workspace.</h1><a className="button secondary" href="#/">Back to dashboard</a></div>}
      </Suspense></ModuleBoundary></main>
    </div>
  </div>;
}
