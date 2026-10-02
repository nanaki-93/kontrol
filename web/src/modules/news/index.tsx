import { useState } from 'react';
import { PageHeader } from '../../components/ui';
import { DiscoveryPage } from './discovery';
import { FeedsPage } from './feeds';

export { NewsWidget } from './widget';

export function NewsPage() {
  const [view, setView] = useState<'discover' | 'feeds'>('discover');
  return <>
    <PageHeader eyebrow="FOLLOW AN INTEREST, FIND THE SIGNAL" title="News"
      description="Specific interests. Fresh sources. A reading list shaped around what matters to you." />
    <nav className="tabs news-tabs" aria-label="News views">
      <button className={view === 'discover' ? 'active' : ''} aria-pressed={view === 'discover'} onClick={() => setView('discover')}>Discover</button>
      <button className={view === 'feeds' ? 'active' : ''} aria-pressed={view === 'feeds'} onClick={() => setView('feeds')}>Saved feeds</button>
    </nav>
    {view === 'discover' ? <DiscoveryPage /> : <FeedsPage />}
  </>;
}
