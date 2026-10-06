import { PageHeader } from '../../components/ui';
import { DiscoveryPage } from './discovery';
import { FeedsPage } from './feeds';
import { Briefing, SavedReading } from './briefing';
import { ExplorePage } from './explore';

export { NewsWidget } from './widget';

export function newsViewFromHash(hash: string): 'briefing' | 'discover' | 'explore' | 'feeds' | 'saved' {
  const view = new URLSearchParams(hash.split('?')[1]).get('view');
  return view === 'discover' || view === 'explore' || view === 'feeds' || view === 'saved' ? view : 'briefing';
}

/** Use the app's hash router for tabs as well as incoming/recovery links. */
export function navigateNewsView(view: ReturnType<typeof newsViewFromHash>, location: Pick<Location, 'hash'> = window.location) {
  location.hash = view === 'briefing' ? '#/news' : '#/news?view=' + view;
}

export function NewsPage() {
  // App remounts routed pages on hashchange; the URL is the sole view owner.
  const view = newsViewFromHash(window.location.hash);
  return <>
    <PageHeader eyebrow="FOLLOW AN INTEREST, FIND THE SIGNAL" title="News"
      description="Specific interests. Fresh sources. A reading list shaped around what matters to you." />
    <nav className="tabs news-tabs" aria-label="News views">
      <button className={view === 'briefing' ? 'active' : ''} aria-pressed={view === 'briefing'} onClick={() => navigateNewsView('briefing')}>Daily briefing</button>
      <button className={view === 'discover' ? 'active' : ''} aria-pressed={view === 'discover'} onClick={() => navigateNewsView('discover')}>Discover</button>
      <button type="button" className={view === 'explore' ? 'active' : ''} aria-pressed={view === 'explore'} onClick={() => navigateNewsView('explore')}>Explore</button>
      <button className={view === 'saved' ? 'active' : ''} aria-pressed={view === 'saved'} onClick={() => navigateNewsView('saved')}>Saved for later</button>
      <button className={view === 'feeds' ? 'active' : ''} aria-pressed={view === 'feeds'} onClick={() => navigateNewsView('feeds')}>Saved feeds</button>
    </nav>
    {view === 'briefing' ? <div className="panel"><Briefing /></div> : view === 'discover' ? <DiscoveryPage /> : view === 'explore' ? <ExplorePage /> : view === 'saved' ? <SavedReading /> : <FeedsPage />}
  </>;
}
