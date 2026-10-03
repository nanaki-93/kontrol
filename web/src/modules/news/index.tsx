import { useState } from 'react';
import { PageHeader } from '../../components/ui';
import { DiscoveryPage } from './discovery';
import { FeedsPage } from './feeds';
import { Briefing, SavedReading } from './briefing';

export { NewsWidget } from './widget';

export function NewsPage() {
  const initial = new URLSearchParams(window.location.hash.split('?')[1]).get('view');
  const [view, setView] = useState(initial && ['discover', 'feeds', 'saved'].includes(initial) ? initial : 'briefing');
  return <>
    <PageHeader eyebrow="FOLLOW AN INTEREST, FIND THE SIGNAL" title="News"
      description="Specific interests. Fresh sources. A reading list shaped around what matters to you." />
    <nav className="tabs news-tabs" aria-label="News views">
      <button className={view === 'briefing' ? 'active' : ''} aria-pressed={view === 'briefing'} onClick={() => setView('briefing')}>Daily briefing</button>
      <button className={view === 'discover' ? 'active' : ''} aria-pressed={view === 'discover'} onClick={() => setView('discover')}>Discover</button>
      <button className={view === 'saved' ? 'active' : ''} aria-pressed={view === 'saved'} onClick={() => setView('saved')}>Saved for later</button>
      <button className={view === 'feeds' ? 'active' : ''} aria-pressed={view === 'feeds'} onClick={() => setView('feeds')}>Saved feeds</button>
    </nav>
    {view === 'briefing' ? <div className="panel"><Briefing /></div> : view === 'discover' ? <DiscoveryPage /> : view === 'saved' ? <SavedReading /> : <FeedsPage />}
  </>;
}
