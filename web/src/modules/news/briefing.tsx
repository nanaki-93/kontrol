import { useState } from 'react';
import { visibleDiscoveries, type NewsResponse } from '../../../shared/news';
import { canonicalURL, groupStories, type Workspace } from '../../../shared/workspace';
import { Badge, Empty, ErrorMessage, Loading } from '../../components/ui';
import { ArticleList, type ReadableArticle } from './articles';
import { useNews } from './api';
import { useWorkspace } from '../workspace/api';

export function briefingStories(news: NewsResponse, workspace?: Workspace) {
  const enabled = new Set(news.preferences.feeds.filter(f => f.isEnabled).map(f => f.id));
  const articles: ReadableArticle[] = [...visibleDiscoveries(news.discovery), ...news.articles.filter(a => a.feedIDs.some(id => enabled.has(id)) && a.topicIDs.some(id => news.preferences.selectedTopicIDs.includes(id)))];
  const terms = [...(workspace?.profile.interests ?? []), ...(workspace?.profile.targetRoles ?? [])].map(s => s.toLowerCase());
  const relevance = (a: ReadableArticle) => terms.filter(t => (a.title + ' ' + a.summary).toLowerCase().includes(t)).length;
  articles.sort((a, b) => relevance(b) - relevance(a) || (b.publishedAt ?? b.fetchedAt).localeCompare(a.publishedAt ?? a.fetchedAt));
  return groupStories(articles).slice(0, 5);
}
export function Briefing({ compact = false }: { compact?: boolean }) {
  const query = useNews(), workspace = useWorkspace();
  if (query.isPending || workspace.isPending) return <Loading />;
  if (!query.data) return <ErrorMessage error={query.error} />;
  const groups = briefingStories(query.data, workspace.data);
  return <><ErrorMessage error={query.error ?? workspace.error} />
    <p className="muted">{compact ? 'Up to five stories from your latest searches and feeds.' : 'Up to five stories from your latest searches and feeds, prioritized by your saved interests. Similar headlines are grouped as related coverage.'}</p>
    {groups.length ? groups.map(group => <div className="briefing-story" key={group.lead.url}><ArticleList articles={[group.lead]} compact={compact} interests={query.data.discovery.preferences.interests} />
      {group.related.length > 0 && <details className="related-coverage"><summary>{group.related.length} related {group.related.length === 1 ? 'source' : 'sources'}</summary><ArticleList articles={group.related} compact /></details>}
    </div>) : <Empty title="Your briefing starts with your interests.">Search your interests in Discover or refresh your saved feeds. Saved stories remain in your library.</Empty>}
    <p className="footnote">Based on your latest refresh, not a live feed. Dates are shown per source.</p>
    <a className="text-link" href="#/news?view=discover">Discover and refresh stories →</a>
  </>;
}
export function SavedReading() {
  const query = useWorkspace(), [unread, setUnread] = useState(false), [search, setSearch] = useState('');
  const records = (query.data?.articles ?? []).filter(a => a.savedAt && (!unread || !a.readAt) &&
    (a.article.title + ' ' + a.article.summary + ' ' + a.notes).toLowerCase().includes(search.toLowerCase())).sort((a, b) => b.savedAt!.localeCompare(a.savedAt!));
  return <div className="panel"><div className="section-title"><h2>Saved for later</h2><Badge>{records.length} stories</Badge></div>
    <div className="toolbar"><label>Search saved reading<input type="search" value={search} onChange={e => setSearch(e.target.value)} /></label><label className="checkbox-label"><input type="checkbox" checked={unread} onChange={e => setUnread(e.target.checked)} />Unread only</label></div>
    <ErrorMessage error={query.error} />{query.isPending ? <Loading /> : records.length ? records.map(record => <div key={canonicalURL(record.article.url)}><ArticleList articles={[record.article]} />{record.notes && <p className="reading-note-excerpt prose-text">Your notes: {record.notes}</p>}</div>) : <Empty title="Keep the stories you want to return to.">Use Save for later on any story. Bookmarks and notes stay here when searches refresh.</Empty>}
  </div>;
}
