import { useState } from 'react';
import { CalendarDays, ChevronDown, ChevronUp, Info, Pause, Plus, Search, Sparkles, Pencil, Trash2 } from 'lucide-react';
import { visibleDiscoveries, discoveryRunError, interestWordCount, MIN_INTEREST_WORDS, type NewsInterest, type SearchMode } from '../../../shared/news';
import { useCommand } from '../../lib/api';
import { Badge, Confirm, Empty, ErrorMessage, IconButton, Loading, formatDate } from '../../components/ui';
import { useNews } from './api';
import { DatedArticleList } from './articles';
import { InterestEditor } from './interest-editor';
import { AIConnection } from './ai-connection';

export function DiscoveryPage() {
  const query = useNews(), command = useCommand(['news']), search = useCommand(['news']);
  const [editing, setEditing] = useState<NewsInterest | 'new' | null>(null);
  const [removing, setRemoving] = useState<NewsInterest | null>(null);
  const [selected, setSelected] = useState(''), [mode, setMode] = useState<SearchMode>('search');
  const [connection, setConnection] = useState(false);
  const [managing, setManaging] = useState(false);
  if (query.isPending) return <Loading />;
  if (query.error) return <ErrorMessage error={query.error} />;
  const state = query.data, discovery = state.discovery, interests = discovery.preferences.interests;
  const active = interests.some(i => i.id === selected) ? selected : '';
  const enabled = interests.filter(i => i.enabled && (!active || i.id === active));
  const broad = enabled.filter(i => interestWordCount(i.query, i.language) < MIN_INTEREST_WORDS);
  const articles = visibleDiscoveries(discovery, active || undefined);
  const busy = search.isPending || state.activity.discovering;
  const runs = enabled.flatMap(i => discovery.runs[i.id] ? [{ interest: i, run: discovery.runs[i.id] }] : []);
  const lastChecked = runs.map(r => r.run.attemptedAt).sort().at(-1);
  const expanded = managing || !interests.length;
  return <>
    <section className="panel interest-settings">
      <div className="section-title"><div><h2>Interests <span className="result-count">{interests.length}</span></h2></div>
        <div className="actions">{interests.length > 0 && <button className="text-link" aria-expanded={expanded} aria-controls="news-interests" onClick={() => setManaging(!expanded)}>{expanded ? 'Hide' : 'Manage'}{expanded ? <ChevronUp size={14} /> : <ChevronDown size={14} />}</button>}
        <button className="button secondary" disabled={interests.length >= 12 || !!editing} onClick={() => { setManaging(true); setEditing('new'); }}><Plus size={16} />Add</button></div></div>
      <div id="news-interests" hidden={!expanded}>
      {interests.length ? <div className="interest-grid">{interests.map(interest => {
        const run = discovery.runs[interest.id];
        return <article className={'interest-card' + (interest.enabled ? '' : ' paused')} key={interest.id}>
          <div className="row-spread"><label className="checkbox-label"><input type="checkbox" checked={interest.enabled} disabled={command.isPending || busy} onChange={e => command.mutate({ path: '/news/interests/' + interest.id, method: 'PUT', body: { ...interest, enabled: e.target.checked, expectedRevision: interest.revision } })} /><strong>{interest.name}</strong></label>
            <div className="actions"><IconButton label={'Edit ' + interest.name} disabled={busy} onClick={() => setEditing(interest)}><Pencil size={14} /></IconButton><IconButton label={'Remove ' + interest.name} className="danger" disabled={busy} onClick={() => setRemoving(interest)}><Trash2 size={14} /></IconButton></div></div>
          <p className="interest-query">{interest.query}</p>
          {interestWordCount(interest.query, interest.language) < MIN_INTEREST_WORDS && <Badge tone="warning">Add detail · {MIN_INTEREST_WORDS} search words minimum</Badge>}
          <div className="article-interests"><Badge>{interest.language === 'ja' ? 'Japanese' : 'English'} · {interest.region}</Badge><Badge icon={CalendarDays}>{interest.days}d</Badge><Badge>{interest.intent === 'opportunities' ? 'Career news' : 'News'}</Badge></div>
          <div className="article-interests"><Badge tone={run?.error && interest.enabled ? 'warning' : ''} icon={!interest.enabled ? Pause : run?.error ? undefined : Search}>{!interest.enabled ? 'Paused' : run?.error ? 'Search failed · Results kept' : run ? run.count + ' matches · ' + formatDate(run.attemptedAt) : 'Not searched'}</Badge></div>
        </article>;
      })}</div> : <Empty title="No interests" />}
      </div>
      <ErrorMessage error={command.error} />
      {removing && <Confirm title={'Remove “' + removing.name + '”?'} description="Removes this interest and its unique matches." label="Remove interest" pending={command.isPending} onCancel={() => setRemoving(null)} onConfirm={() => command.mutate({ path: '/news/interests/' + removing.id, method: 'DELETE', body: { expectedRevision: removing.revision } }, { onSuccess: () => { if (editing !== 'new' && editing?.id === removing.id) setEditing(null); setRemoving(null); } })} />}
    </section>
    {editing && <InterestEditor key={editing === 'new' ? 'new' : editing.id + editing.revision} interest={editing === 'new' ? undefined : editing} onClose={() => setEditing(null)} />}
    <div className="panel">
      <div className="news-search-controls">
        <label>Interest<select value={active} onChange={e => setSelected(e.target.value)}><option value="">All enabled interests</option>{interests.map(i => <option value={i.id} key={i.id}>{i.name}{i.enabled ? '' : ' (paused)'}</option>)}</select></label>
        <label>Mode<select value={mode} disabled={busy} onChange={e => setMode(e.target.value as SearchMode)}><option value="search">Standard</option><option value="ai">AI · PI</option></select></label>
        <button className="button primary" disabled={busy || !enabled.length || broad.length > 0 || (mode === 'ai' && !state.ai.configured)} onClick={() => search.mutate({ path: '/news/discover', body: { mode, ...(active ? { interestID: active } : {}) } })}>
          {mode === 'ai' ? <Sparkles size={16} className={busy ? 'spin' : ''} /> : <Search size={16} className={busy ? 'spin' : ''} />}{busy ? 'Searching…' : 'Search'}
        </button>
      </div>
      {broad.length > 0 && <p className="inline-note">Edit {broad.map(i => '“' + i.name + '”').join(', ')} to use at least {MIN_INTEREST_WORDS} search words, or pause {broad.length === 1 ? 'it' : 'them'}.</p>}
      {mode === 'ai' && <p className="inline-note"><Info size={14} aria-hidden="true" />PI provider charges apply</p>}
      <button className="connection-toggle" aria-expanded={connection || (mode === 'ai' && !state.ai.configured)} onClick={() => setConnection(!connection)}><Badge tone={state.ai.configured ? 'success' : 'warning'}>PI {state.ai.configured ? 'connected' : 'unavailable'}</Badge><ChevronDown size={14} aria-hidden="true" /></button>
      {(connection || (mode === 'ai' && !state.ai.configured)) && <AIConnection ai={state.ai} searching={busy} />}
      <ErrorMessage error={search.error} />
      {runs.filter(({ run }) => run.error).map(({ interest, run }) => <ErrorMessage key={interest.id} error={discoveryRunError(interest.name, run.error!)} />)}
      {busy && <p className="footnote" role="status" aria-live="polite">Searching sources…</p>}
    </div>
    <div className="panel"><div className="section-title"><h2>{active ? interests.find(i => i.id === active)?.name : 'Search results'}</h2><Badge>{articles.length} matches · Newest first</Badge></div>
      {articles.length ? <DatedArticleList articles={articles} interests={active ? enabled : interests} /> : <Empty title={busy ? 'Searching…' : !enabled.length ? 'No active interests' : runs.some(r => !r.run.error) ? 'No matches' : 'No search results yet'} />}
      {lastChecked && <p className="inline-note"><Search size={13} aria-hidden="true" />{new Date(lastChecked).toLocaleString()}</p>}
    </div>
  </>;
}
