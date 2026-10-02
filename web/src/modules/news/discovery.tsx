import { useState } from 'react';
import { Plus, Search, Sparkles, Pencil, Trash2 } from 'lucide-react';
import { visibleDiscoveries, type NewsInterest, type SearchMode } from '../../../shared/news';
import { useCommand } from '../../lib/api';
import { Badge, Confirm, Empty, ErrorMessage, Loading, formatDate } from '../../components/ui';
import { useNews } from './api';
import { ArticleList } from './articles';
import { InterestEditor } from './interest-editor';
import { AIConnection } from './ai-connection';

export function DiscoveryPage() {
  const query = useNews(), command = useCommand(['news']), search = useCommand(['news']);
  const [editing, setEditing] = useState<NewsInterest | 'new' | null>(null);
  const [removing, setRemoving] = useState<NewsInterest | null>(null);
  const [selected, setSelected] = useState(''), [mode, setMode] = useState<SearchMode>('search');
  const [connection, setConnection] = useState(false);
  if (query.isPending) return <Loading />;
  if (query.error) return <ErrorMessage error={query.error} />;
  const state = query.data, discovery = state.discovery, interests = discovery.preferences.interests;
  const active = interests.some(i => i.id === selected) ? selected : '';
  const enabled = interests.filter(i => i.enabled && (!active || i.id === active));
  const articles = visibleDiscoveries(discovery, active || undefined);
  const busy = search.isPending || state.activity.discovering;
  const runs = enabled.flatMap(i => discovery.runs[i.id] ? [{ interest: i, run: discovery.runs[i.id] }] : []);
  const lastChecked = runs.map(r => r.run.attemptedAt).sort().at(-1);
  return <>
    <div className="panel">
      <div className="section-title"><div><h2>Your interests</h2><p className="muted">Follow a precise question across sources, without subscribing to individual websites.</p></div>
        <button className="button secondary" disabled={interests.length >= 12 || !!editing} onClick={() => setEditing('new')}><Plus size={16} />Add interest</button></div>
      {interests.length ? <div className="interest-grid">{interests.map(interest => {
        const run = discovery.runs[interest.id];
        return <article className={'interest-card' + (interest.enabled ? '' : ' paused')} key={interest.id}>
          <div className="row-spread"><label className="checkbox-label"><input type="checkbox" checked={interest.enabled} disabled={command.isPending || busy} onChange={e => command.mutate({ path: '/news/interests/' + interest.id, method: 'PUT', body: { ...interest, enabled: e.target.checked, expectedRevision: interest.revision } })} /><strong>{interest.name}</strong></label>
            <div className="actions"><button className="icon-button" aria-label={'Edit ' + interest.name} disabled={busy} onClick={() => setEditing(interest)}><Pencil size={14} /></button><button className="icon-button" aria-label={'Remove ' + interest.name} disabled={busy} onClick={() => setRemoving(interest)}><Trash2 size={14} /></button></div></div>
          <p className="interest-query">{interest.query}</p>
          <div className="article-interests"><Badge>{interest.language === 'ja' ? 'Japanese' : 'English'} · {interest.region}</Badge><Badge>{interest.days === 1 ? '24 hours' : interest.days + ' days'}</Badge><Badge>{interest.intent === 'opportunities' ? 'Opportunities' : 'News'}</Badge></div>
          <p className="footnote">{!interest.enabled ? 'Paused' : run?.error ? 'Last search failed · saved results retained' : run ? run.count + ' matches at last search · ' + formatDate(run.attemptedAt) : 'Ready for your first search'}</p>
        </article>;
      })}</div> : <Empty title="Start with something specific.">Try programming jobs in Japan, or new AI models and benchmarks.</Empty>}
      <ErrorMessage error={command.error} />
      {removing && <Confirm title={'Remove “' + removing.name + '”?'} description="This removes the interest and its saved matches. Articles matching other interests remain." label="Remove interest" pending={command.isPending} onCancel={() => setRemoving(null)} onConfirm={() => command.mutate({ path: '/news/interests/' + removing.id, method: 'DELETE', body: { expectedRevision: removing.revision } }, { onSuccess: () => { if (editing !== 'new' && editing?.id === removing.id) setEditing(null); setRemoving(null); } })} />}
    </div>
    {editing && <InterestEditor key={editing === 'new' ? 'new' : editing.id + editing.revision} interest={editing === 'new' ? undefined : editing} onClose={() => setEditing(null)} />}
    <div className="panel">
      <div className="news-search-controls">
        <label>Interest<select value={active} onChange={e => setSelected(e.target.value)}><option value="">All enabled interests</option>{interests.map(i => <option value={i.id} key={i.id}>{i.name}{i.enabled ? '' : ' (paused)'}</option>)}</select></label>
        <label>Search method<select value={mode} disabled={busy} onChange={e => setMode(e.target.value as SearchMode)}><option value="search">Standard · no API key</option><option value="ai">AI · PI search</option></select></label>
        <button className="button primary" disabled={busy || !enabled.length || (mode === 'ai' && !state.ai.configured)} onClick={() => search.mutate({ path: '/news/discover', body: { mode, ...(active ? { interestID: active } : {}) } })}>
          {mode === 'ai' ? <Sparkles size={16} className={busy ? 'spin' : ''} /> : <Search size={16} className={busy ? 'spin' : ''} />}{busy ? 'Searching…' : 'Search ' + (active ? 'interest' : 'interests')}
        </button>
      </div>
      <p className="footnote">{mode === 'search' ? 'Searches Google News across publishers, then filters and ranks by your interests. For direct job listings and detailed requests, try AI search.' : 'Uses PI to rank and summarize live news and web search results for each selected interest (' + enabled.length + '). Only retrieved source links are accepted; your PI provider’s usage limits apply.'} Searches run only when you ask.</p>
      <button className="text-link" aria-expanded={connection || (mode === 'ai' && !state.ai.configured)} onClick={() => setConnection(!connection)}><Sparkles size={14} />{state.ai.configured ? 'PI connection' : 'Set up PI search'}</button>
      {(connection || (mode === 'ai' && !state.ai.configured)) && <AIConnection ai={state.ai} searching={busy} />}
      <ErrorMessage error={search.error} />
      {runs.filter(({ run }) => run.error).map(({ interest, run }) => <ErrorMessage key={interest.id} error={interest.name + ': ' + run.error + ' Saved results are retained.'} />)}
      {busy && <p className="footnote" role="status" aria-live="polite">Finding matching sources. AI searches can take up to a minute per interest; you can keep using the dashboard.</p>}
    </div>
    <div className="panel"><div className="section-title"><h2>{active ? interests.find(i => i.id === active)?.name : 'Your reading list'}</h2><Badge>{articles.length} matches</Badge></div>
      {articles.length ? <ArticleList articles={articles} interests={interests} /> : <Empty title={busy ? 'Looking for relevant results…' : !enabled.length ? 'Choose an active interest.' : runs.some(r => !r.run.error) ? 'No matches within these filters.' : 'Your interests are ready.'}>
        {!enabled.length ? 'Add or enable an interest to start discovering sources.' : runs.some(r => !r.run.error) ? 'Try a longer date window, fewer required keywords, or AI search for a more detailed request.' : 'Search above to fill your reading list. Saved results stay available offline.'}
      </Empty>}
      {lastChecked && <p className="footnote">Last search attempt: {new Date(lastChecked).toLocaleString()}. Undated results are labeled; publication dates and job availability may need checking at the source.</p>}
    </div>
  </>;
}
