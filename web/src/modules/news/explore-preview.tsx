import { useQueryClient } from '@tanstack/react-query';
import { Badge, Empty, ErrorMessage } from '../../components/ui';
import { groupStories, canonicalURL } from '../../../shared/workspace';
import type { NewsResponse } from '../../../shared/news';
import {
  EXPLORE_MAX_CONCURRENT_SEARCHES, EXPLORE_MAX_QUERY_CHARS, exploreSearchSchema, type ExplorePreview, type ExploreSearch,
} from '../../../shared/news-explore';
import { ArticleList } from './articles';
import { setExploreSearchDraft, useExploreRecovery, useExploreSearch } from './explore-api';
import { expireExploreState, retainedExploreResult, type ExploreClientState } from './explore-state';

const previewMessages: Record<ExplorePreview['state'], string> = {
  'not-searched': 'No search yet. Review the proposed search, then explicitly search this topic. Selecting an idea does not fetch news.',
  pending: 'Searching this topic with Standard search… Any previous same-topic coverage below is retained, not a result of this attempt.',
  successful: 'Retrieved coverage for this topic. These are source excerpts, not AI-written reporting.',
  'successful-empty': 'No stories found for this angle. The search succeeded with zero results; older coverage is no longer current. Review the search or try another topic.',
  failed: 'The search failed. No coverage has been retrieved for this topic. Review the search and try again explicitly.',
  'failed-retained': 'The refresh failed. Previous same-topic coverage is retained with its original search and last-success time, not the failed attempt below.',
  uncertain: 'The search outcome is unknown. Check local status before searching again; this does not repeat the external search. Any previous coverage is retained below.',
  obsolete: 'This topic is obsolete because its source interest changed or was replaced. Request new ideas explicitly. Saved reading is unaffected.',
  expired: 'This temporary preview expired or is unavailable after a server restart. Check local status or request new ideas explicitly. Nothing reruns automatically.',
};
function sameSearch(a: ExploreSearch, b: ExploreSearch): boolean {
  return a.query === b.query && a.language === b.language && a.region === b.region && a.days === b.days;
}
/** Pure selected-topic presentation. Never mix a draft/attempt with the search
 * that produced coverage, or borrow another topic's result. No briefing cap.
 */
export function exploreReadingPreviewModel(supplied: ExploreClientState, news?: NewsResponse, now = Date.now()) {
  const state = expireExploreState(supplied, now);
  const session = state.lifecycle.state === 'available' ? state.lifecycle.session : null;
  const topic = session?.topics.find(topic => topic.id === state.selectedTopicID) ?? null;
  const source = news?.discovery.preferences.interests.find(interest => topic && interest.enabled &&
    interest.id === topic.sourceInterestID && interest.revision === topic.sourceInterestRevision);
  const preview: ExplorePreview | null = state.lifecycle.state === 'expired' ? { state: 'expired' } :
    state.lifecycle.state === 'obsolete' ? { state: 'obsolete' } : topic ?
      topic.status === 'obsolete' || (news && !source) ? { state: 'obsolete' } : topic.preview : null;
  const result = preview ? retainedExploreResult(preview) : null;
  const attempt = preview && 'attempt' in preview ? preview.attempt : null;
  const search = topic ? state.drafts[topic.id] ?? topic.proposedSearch : null;
  const validation = search ? exploreSearchSchema.safeParse(search) : null;
  const searchable = !!topic && topic.status === 'available' && preview?.state !== 'obsolete' && preview?.state !== 'expired';
  const busy = preview?.state === 'pending' || preview?.state === 'uncertain' || !!(topic && state.searchRequestIDs[topic.id]);
  const atSearchCapacity = (session?.topics.filter(topic => topic.preview.state === 'pending').length ?? 0) >= EXPLORE_MAX_CONCURRENT_SEARCHES;
  return {
    topic, search, result, attempt, previewState: preview?.state ?? null,
    sourceLabel: source?.name ?? (news ? 'Source interest changed or unavailable' : 'Saved source interest (settings unavailable)'),
    message: preview ? previewMessages[preview.state] : null,
    error: preview && 'error' in preview ? preview.error.error : null,
    validationError: validation && !validation.success ? validation.error.issues[0]?.message ?? 'Review the search.' : null,
    editable: searchable,
    canSearch: searchable && !!validation?.success && !busy && !atSearchCapacity && state.recovery.state !== 'pending',
    atSearchCapacity, canRecover: state.recovery.state !== 'pending',
    searchLabel: preview?.state === 'pending' ? 'Searching · Standard…' : result ? 'Search again · Standard' : 'Search this topic · Standard',
    draftDiffers: !!search && !!result && !sameSearch(search, result.search),
    retained: !!result && !!preview && 'previous' in preview,
    groups: groupStories(result?.articles ?? []),
  };
}

function SearchParameters({ search }: { search: ExploreSearch }) {
  return <dl className="explore-search-parameters">
    <div><dt>Query</dt><dd>{search.query}</dd></div>
    <div><dt>Search scope</dt><dd>{search.language === 'ja' ? 'Japanese' : 'English'} · {search.region} · Past {search.days} {search.days === 1 ? 'day' : 'days'} · Standard news search</dd></div>
  </dl>;
}
function SearchTime({ value }: { value: string }) {
  return <time dateTime={value} title={value}>{new Date(value).toLocaleString()}</time>;
}

export function ExploreReadingPreview({ state, news }: { state: ExploreClientState; news?: NewsResponse }) {
  const client = useQueryClient(), command = useExploreSearch(), recover = useExploreRecovery();
  const model = exploreReadingPreviewModel(state, news);
  if (!model.previewState) return null;
  const topic = model.topic, search = model.search;
  const recovery = <div className="actions"><button type="button" className="button secondary" disabled={!model.canRecover}
    onClick={() => recover.mutate()}>{model.canRecover ? 'Check local status' : 'Checking local status…'}</button>
    <span className="footnote">Local recovery only — no PI or news search.</span></div>;
  return <section className="panel explore-reading" aria-labelledby="explore-preview-title">
    <header className="explore-preview-head">
      <Badge>Temporary Standard preview</Badge>
      <h2 id="explore-preview-title">{topic?.title ?? 'Temporary preview unavailable'}</h2>
      {topic && <p className="explore-connection"><strong>Connected to: {model.sourceLabel}</strong><br />Suggested connection: {topic.connection}</p>}
      <p className="muted">Search real coverage without following this topic or changing your briefing. PI suggests the direction; Standard search retrieves the sources.</p>
    </header>
    {topic && search && <form className="editor explore-search-editor" onSubmit={event => {
      event.preventDefault();
      if (model.canSearch) command.mutate({ topicID: topic.id });
    }}>
      <fieldset disabled={!model.editable}>
        <legend>Review the search</legend>
        <label>News search query<textarea rows={3} maxLength={EXPLORE_MAX_QUERY_CHARS} value={search.query}
          aria-describedby="explore-query-help" aria-invalid={!!model.validationError}
          onChange={event => setExploreSearchDraft(client, topic.id, { ...search, query: event.target.value })} /></label>
        <p className="footnote" id="explore-query-help">Use at least 5 search words. Proposed locale and freshness come from the source interest; its required/excluded keyword filters are not carried over. Editing does not search.</p>
        <div className="explore-search-locales">
          <label>Language<select value={search.language} onChange={event => setExploreSearchDraft(client, topic.id, { ...search, language: event.target.value as ExploreSearch['language'] })}>
            <option value="en">English</option><option value="ja">Japanese</option></select></label>
          <label>Region<select value={search.region} onChange={event => setExploreSearchDraft(client, topic.id, { ...search, region: event.target.value as ExploreSearch['region'] })}>
            {['US', 'JP', 'GB', 'PH'].map(region => <option key={region} value={region}>{region}</option>)}</select></label>
          <label>Freshness<select value={search.days} onChange={event => setExploreSearchDraft(client, topic.id, { ...search, days: Number(event.target.value) as ExploreSearch['days'] })}>
            <option value={1}>Past day</option><option value={7}>Past 7 days</option><option value={30}>Past 30 days</option></select></label>
        </div>
      </fieldset>
      <ErrorMessage error={model.validationError} />
      <div className="actions"><button type="submit" className="button primary" disabled={!model.canSearch}>{model.searchLabel}</button>
        <span className="footnote">Standard only · No PI call · No automatic retry</span></div>
      {model.atSearchCapacity && model.previewState !== 'pending' && <p className="footnote" role="status">Two topic searches are already running. Wait or check local status.</p>}
    </form>}
    <p className="explore-preview-status" role="status" aria-live="polite">{model.message}</p>
    {/* Errors belong to the cached topic, not the mutation observer's latest
        request (which may be a duplicate or a different topic). */}
    <ErrorMessage error={model.error} />
    {model.attempt && <details className="explore-attempt" open={model.previewState !== 'pending'}>
      <summary>{model.previewState === 'pending' ? 'Search in progress' : model.previewState === 'uncertain' ? 'Unconfirmed search attempt' : 'Failed search attempt'}</summary>
      <p className="footnote">Attempt started: <SearchTime value={model.attempt.startedAt} /></p>
      <SearchParameters search={model.attempt.search} />
    </details>}
    {['pending', 'uncertain', 'expired', 'obsolete'].includes(model.previewState) && recovery}
    {model.result && <div className="explore-coverage">
      <div className="explore-producing-search">
        <h3>{model.retained ? 'Retained coverage — original search' : 'Coverage — producing search'}</h3>
        <p className="footnote">Last successful search: <SearchTime value={model.result.succeededAt} /></p>
        <SearchParameters search={model.result.search} />
        {model.draftDiffers && <p className="footnote">The editable draft differs from this coverage’s producing search. Changes apply only after a successful explicit search.</p>}
      </div>
      {model.result.articles.length > 0 ? <>
        <p className="footnote">{model.result.articles.length} retrieved {model.result.articles.length === 1 ? 'article' : 'articles'} · Source excerpts only. Related coverage is grouped heuristically, not verified as the same event.</p>
        {model.groups.map(group => <div className="explore-story" key={canonicalURL(group.lead.url)}>
          <ArticleList articles={[group.lead]} />
          {group.related.length > 0 && <details className="related-coverage">
            <summary>Related coverage · {group.related.length} · Heuristic match</summary>
            <ArticleList articles={group.related} />
          </details>}
        </div>)}
      </> : <Empty title={model.retained ? 'Previous successful search found no stories' : 'No stories found for this angle'}>
        {model.retained ? 'This is the retained empty result, not a result of the latest attempt.' : 'Try another topic or review the search. No unrelated filler stories were added.'}
      </Empty>}
    </div>}
    <footer className="explore-preview-end">
      <p>{model.result ? 'That’s this preview. Keep a story or try another direction.' : 'Explore at your own pace. Nothing is followed automatically.'}</p>
      <p className="footnote">Saved articles and authored notes remain available independently of this temporary preview.</p>
      {topic && <button type="button" className="text-link" aria-controls="explore-ideas-title" onClick={() => {
        // Keep the app's News hash route intact while returning to the gallery.
        const ideas = document.getElementById('explore-ideas-title');
        ideas?.focus({ preventScroll: true }); ideas?.scrollIntoView();
      }}>Back to topic ideas ↑</button>}
    </footer>
  </section>;
}
