import { Search } from 'lucide-react';
import { visibleDiscoveries } from '../../../shared/news';
import { useCommand } from '../../lib/api';
import { Empty, ErrorMessage, Loading } from '../../components/ui';
import { useNews } from './api';
import { ArticleList } from './articles';

export function NewsWidget() {
  const query = useNews(), command = useCommand(['news']);
  if (query.isPending) return <Loading />;
  if (query.error) return <ErrorMessage error={query.error} />;
  const state = query.data.discovery, interests = state.preferences.interests.filter(i => i.enabled);
  const articles = visibleDiscoveries(state), busy = command.isPending || query.data.activity.discovering;
  const errors = interests.filter(i => state.runs[i.id]?.error).length;
  return <><div className="row-spread"><span className="row-meta">{interests.length} interests · across sources</span><button className="text-link" disabled={busy || !interests.length} onClick={() => command.mutate({ path: '/news/discover', body: { mode: 'search' } })}><Search size={13} className={busy ? 'spin' : ''} />{busy ? 'Searching…' : 'Standard search'}</button></div>
    <ErrorMessage error={command.error} />{errors > 0 && <p className="warning-text">{errors} interests could not refresh. Open News for details; saved results are retained.</p>}
    {articles.length ? <ArticleList articles={articles.slice(0, 4)} compact /> : <Empty title="Keep up with what matters.">Search your interests to find relevant articles across publishers. Refine interests and connect optional AI in News.</Empty>}</>;
}
