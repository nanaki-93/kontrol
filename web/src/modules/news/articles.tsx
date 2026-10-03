import { useState } from 'react';
import { ArrowUpRight, Bookmark, Check, Pencil } from 'lucide-react';
import type { Article } from '../../../shared/schema';
import type { DiscoveredArticle, NewsInterest } from '../../../shared/news';
import { canonicalURL, type SavedArticle } from '../../../shared/workspace';
import { Badge, ErrorMessage, formatDate } from '../../components/ui';
import { useWorkspace, useWorkspaceCommand } from '../workspace/api';

export type ReadableArticle = Article | DiscoveredArticle | SavedArticle['article'];
function ReadingNotes({ article, notes }: { article: ReadableArticle; notes: string }) {
  const command = useWorkspaceCommand(), [draft, setDraft] = useState(notes), [baseline, setBaseline] = useState(notes), [saved, setSaved] = useState(false);
  return <form className="editor reading-notes" onSubmit={async e => {
    e.preventDefault(); setSaved(false);
    try { await command.mutateAsync({ path: '/articles', method: 'PUT', body: { url: article.url, notes: draft, expectedNotes: baseline } }); setBaseline(draft); setSaved(true); } catch { /* Preserve draft. */ }
  }}><label>Your notes & highlights<textarea rows={3} maxLength={20_000} value={draft} onChange={e => { setDraft(e.target.value); setSaved(false); }} /></label>
    <ErrorMessage error={command.error} /><div className="actions"><button className="button secondary" disabled={command.isPending}>Save reading notes</button>{saved && <span className="success-text" role="status">Saved</span>}
      {command.error && <button type="button" className="text-link" onClick={() => { setBaseline(notes); command.reset(); }}>Keep my draft for the next save</button>}</div>
    {command.error && <details><summary>Review the currently saved notes</summary><p className="prose-text">{notes || 'No notes saved'}</p></details>}</form>;
}
function ArticleActions({ article, compact }: { article: ReadableArticle; compact: boolean }) {
  const query = useWorkspace(), command = useWorkspaceCommand(), [editing, setEditing] = useState(false);
  const record = query.data?.articles.find(a => canonicalURL(a.article.url) === canonicalURL(article.url));
  const busy = !query.data || command.isPending;
  return <><div className="reading-actions">
    <button className="text-link" aria-pressed={!!record?.savedAt} disabled={busy} onClick={() => command.mutate({ path: '/articles', method: 'PUT', body: { url: article.url, saved: !record?.savedAt } })}><Bookmark size={13} />{record?.savedAt ? 'Saved' : 'Save for later'}</button>
    <button className="text-link" aria-pressed={!!record?.readAt} disabled={busy} onClick={() => command.mutate({ path: '/articles', method: 'PUT', body: { url: article.url, read: !record?.readAt } })}><Check size={13} />{record?.readAt ? 'Read · mark unread' : 'Mark read'}</button>
    {!compact && <><button className="text-link" aria-expanded={editing} disabled={busy} onClick={() => setEditing(!editing)}><Pencil size={13} />Notes</button>
      <a className="text-link" href={'#/learning?explore=' + encodeURIComponent(article.title)}>Explore in Learning →</a></>}
  </div><ErrorMessage error={command.error ?? query.error} />{editing && <ReadingNotes article={article} notes={record?.notes ?? ''} />}</>;
}
export function ArticleList({ articles, compact = false, interests = [] }: {
  articles: ReadableArticle[]; compact?: boolean; interests?: NewsInterest[];
}) {
  return <ul className={'article-list ' + (compact ? 'compact' : '')}>{articles.map(article => {
    const matches = 'matches' in article ? article.matches : [], ai = matches.some(m => m.mode === 'ai') || ('summaryKind' in article && article.summaryKind === 'ai-snippet');
    return <li key={canonicalURL(article.url)}>
      <div className="article-meta"><span>{article.source}</span><span>{article.publishedAt ? formatDate(article.publishedAt) : 'Publication date unavailable'}</span>{ai && <Badge>AI selected</Badge>}</div>
      <a href={article.url} target="_blank" rel="noopener noreferrer"><h3>{article.title}</h3><ArrowUpRight size={17} /></a>
      {!compact && <>
        {article.summary && <p className="brief-summary">{article.summary}</p>}
        {article.summary && <p className="footnote">{ai ? 'AI summary of retrieved snippets. Read the source for full context.' : 'Source excerpt. Read the original for full context.'}</p>}
        {matches.length > 0 && <details><summary>Why this is relevant</summary>{matches.map(match => <p className="match-reason" key={match.interestID}>
          <strong>{interests.find(i => i.id === match.interestID)?.name ?? 'Your interest'}: </strong>{match.reason}
        </p>)}</details>}
      </>}
      <ArticleActions article={article} compact={compact} />
    </li>;
  })}</ul>;
}
