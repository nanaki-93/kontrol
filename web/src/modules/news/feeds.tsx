import { useState, type FormEvent } from 'react';
import { RefreshCw, Rss, Plus, Trash2 } from 'lucide-react';
import type { Article, NewsState } from '../../../shared/schema';
import { useCommand } from '../../lib/api';
import { useNews } from './api';
import { ArticleList } from './articles';
import { PageHeader, Empty, ErrorMessage, Loading, Badge, Confirm } from '../../components/ui';

function visibleArticles(state: NewsState): Article[] {
  const enabled = new Set(state.preferences.feeds.filter(f => f.isEnabled).map(f => f.id));
  return state.articles.filter(a => a.feedIDs.some(id => enabled.has(id)) &&
    a.topicIDs.some(id => state.preferences.selectedTopicIDs.includes(id)));
}
export function FeedsPage() {
  const query = useNews(), command = useCommand(['news']);
  const [manage, setManage] = useState(false), [name, setName] = useState(''), [endpoint, setEndpoint] = useState(''), [topics, setTopics] = useState('software-engineering');
  const [removing, setRemoving] = useState<string | null>(null);
  async function add(e: FormEvent) {
    e.preventDefault();
    try {
      await command.mutateAsync({ path: '/news/feeds', body: { name, endpoint, topicIDs: topics.split(',').map(t => t.trim()).filter(Boolean), isEnabled: true } });
      setName(''); setEndpoint('');
    } catch { /* Retain draft. */ }
  }
  const state = query.data;
  const topicIDs = [...new Set(state?.preferences.feeds.flatMap(f => f.topicIDs) ?? [])].sort();
  const articles = state ? visibleArticles(state) : [];
  function toggleTopic(id: string) {
    const selected = state!.preferences.selectedTopicIDs;
    command.mutate({ path: '/news/topics', method: 'PUT', body: selected.includes(id) ? selected.filter(t => t !== id) : [...selected, id] });
  }
  return <><PageHeader title="Saved feeds" description="Optional subscriptions to publishers you already follow."
    action={<><button className="button secondary" onClick={() => setManage(!manage)}><Rss size={16} /> Manage feeds</button><button className="button primary" disabled={command.isPending} onClick={() => command.mutate({ path: '/news/refresh' })}><RefreshCw size={16} className={command.isPending ? 'spin' : ''} /> Refresh</button></>} />
    <ErrorMessage error={query.error ?? command.error} />
    {manage && <div className="panel"><h2>Your feeds</h2><p className="muted">Feeds refresh when you ask. Articles are cached locally for up to 30 days.</p>
      <ul className="feed-list">{state?.preferences.feeds.map(feed => <li key={feed.id}><label className="checkbox-label"><input type="checkbox" checked={feed.isEnabled} disabled={command.isPending} onChange={e => command.mutate({ path: '/news/feeds/' + feed.id, method: 'PATCH', body: { isEnabled: e.target.checked } })} /><span><strong>{feed.name}</strong><span className="row-meta break-word">{feed.endpoint}</span></span></label><button className="icon-button" onClick={() => setRemoving(feed.id)} aria-label={'Remove ' + feed.name}><Trash2 size={15} /></button></li>)}</ul>
      {removing && <Confirm title="Remove this feed?" description="Articles contributed only by this feed will be removed from the local cache." label="Remove feed" pending={command.isPending} onCancel={() => setRemoving(null)}
        onConfirm={() => command.mutate({ path: '/news/feeds/' + removing, method: 'DELETE' }, { onSuccess: () => setRemoving(null) })} />}
      <form className="editor" onSubmit={add}><div className="form-grid"><label>Feed name<input required value={name} onChange={e => setName(e.target.value)} placeholder="A source worth reading" /></label><label>RSS or Atom URL<input required type="url" value={endpoint} onChange={e => setEndpoint(e.target.value)} placeholder="https://example.com/feed.xml" /></label></div>
        <label>Topic IDs <span className="muted">(comma separated)</span><input required value={topics} onChange={e => setTopics(e.target.value)} /></label><button className="button secondary" disabled={command.isPending}><Plus size={16} /> Add feed</button></form>
    </div>}
    <div className="topic-chips" aria-label="News topics">{topicIDs.map(id => <button key={id} className={state?.preferences.selectedTopicIDs.includes(id) ? 'selected' : ''} aria-pressed={state?.preferences.selectedTopicIDs.includes(id)} disabled={command.isPending} onClick={() => toggleTopic(id)}>{id.replaceAll('-', ' ')}</button>)}</div>
    {state && Object.entries(state.errors).map(([id, error]) => <ErrorMessage key={id} error={(state.preferences.feeds.find(f => f.id === id)?.name ?? 'Feed') + ': ' + error} />)}
    <div className="panel"><div className="section-title"><h2>Your reading list</h2><Badge>{articles.length} articles</Badge></div>
      {query.isPending ? <Loading /> : articles.length ? <ArticleList articles={articles} /> : <Empty title="Nothing competing for your attention.">Select some topics and refresh your feeds when you are ready to read.</Empty>}
      {state?.lastRefreshAt && <p className="footnote">Last refresh attempt: {new Date(state.lastRefreshAt).toLocaleString()}. Missing publication dates are left unknown.</p>}
    </div>
  </>;
}
