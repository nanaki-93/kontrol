import { visibleDiscoveries, type NewsResponse } from './news';
import { groupStories, type Workspace } from './workspace';

export function briefingStories(news: NewsResponse, workspace?: Workspace, now = Date.now()) {
  const enabled = new Set(news.preferences.feeds.filter(f => f.isEnabled).map(f => f.id));
  const articles = [...visibleDiscoveries(news.discovery, undefined, now), ...news.articles.filter(a =>
    a.feedIDs.some(id => enabled.has(id)) && a.topicIDs.some(id => news.preferences.selectedTopicIDs.includes(id)))];
  const terms = [...(workspace?.profile.interests ?? []), ...(workspace?.profile.targetRoles ?? [])].map(s => s.toLowerCase());
  const ranked = articles.map(article => {
    const text = (article.title + ' ' + article.summary).toLowerCase();
    return { article, score: terms.filter(term => text.includes(term)).length };
  }).sort((a, b) => b.score - a.score || (b.article.publishedAt ?? b.article.fetchedAt).localeCompare(a.article.publishedAt ?? a.article.fetchedAt));
  // Retain related coverage even when it appears after the first five leads.
  return groupStories(ranked.map(item => item.article), 5);
}
