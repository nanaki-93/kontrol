import { ArrowUpRight } from 'lucide-react';
import type { Article } from '../../../shared/schema';
import type { DiscoveredArticle, NewsInterest } from '../../../shared/news';
import { Badge, formatDate } from '../../components/ui';

export function ArticleList({ articles, compact = false, interests = [] }: {
  articles: (Article | DiscoveredArticle)[]; compact?: boolean; interests?: NewsInterest[];
}) {
  return <ul className={'article-list ' + (compact ? 'compact' : '')}>{articles.map(article => {
    const matches = 'matches' in article ? article.matches : [];
    const ai = matches.some(m => m.mode === 'ai');
    return <li key={article.id}>
      <div className="article-meta"><span>{article.source}</span><span>{article.publishedAt ? formatDate(article.publishedAt) : 'Publication date unavailable'}</span>{ai && <Badge>AI selected</Badge>}</div>
      <a href={article.url} target="_blank" rel="noopener noreferrer"><h3>{article.title}</h3><ArrowUpRight size={17} /></a>
      {!compact && <>
        {(article.summary || matches.length > 0) && <details><summary>{ai ? 'AI summary & match details' : 'Summary & match details'}</summary>
          {article.summary && <p className="prose-text">{article.summary}</p>}
          {matches.map(match => <p className="match-reason" key={match.interestID}>
            <strong>{interests.find(i => i.id === match.interestID)?.name ?? 'Your interest'}: </strong>{match.reason}
            {match.mode === 'ai' && <span className="row-meta">AI relevance estimate: {match.score}/100. Check the linked source for details.</span>}
          </p>)}
        </details>}
        {matches.length > 0 && <div className="article-interests">{matches.map(match => <Badge key={match.interestID}>{interests.find(i => i.id === match.interestID)?.name ?? 'Your interest'}</Badge>)}</div>}
      </>}
    </li>;
  })}</ul>;
}
