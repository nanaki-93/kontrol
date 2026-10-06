import { useState } from 'react';
import { useQueryClient, type QueryClient } from '@tanstack/react-query';
import { Badge, Empty, ErrorMessage } from '../../components/ui';
import { EXPLORE_MAX_TOPICS } from '../../../shared/news-explore';
import type { NewsResponse } from '../../../shared/news';
import { useNews } from './api';
import {
  beginExploreFollowReview, cancelExploreFollowReview, readExploreState, selectExploreTopic, setExploreFollowDraft,
  useExploreFollow, useExploreGeneration, useExploreRecovery, useExploreState,
} from './explore-api';
import {
  expireExploreState, reconcileExploreState, exploreFollowNextAction,
  type ExploreClientState, type ExploreFollowReview, type ExploreFollowResult,
} from './explore-state';
import { InterestEditor, type InterestEditorProps } from './interest-editor';
import { ExploreReadingPreview } from './explore-preview';

type FollowSubmission = { topicID: string; reviewID: string; draft: ExploreFollowReview['draft'] };
type SubmitFollow = (variables: FollowSubmission) => Promise<ExploreFollowResult>;

/** Creation-only editor wiring. No ordinary interest POST/PUT or search path. */
export function exploreFollowEditorProps(client: QueryClient, review: ExploreFollowReview, submit: SubmitFollow): InterestEditorProps {
  return { editorID: review.reviewID, initialDraft: review.draft, headingLevel: 3,
    onCreate: async draft => {
      setExploreFollowDraft(client, review.reviewID, draft);
      return submit({ topicID: review.topicID, reviewID: review.reviewID, draft });
    },
    onClose: () => {
      // InterestEditor closes after success too. Keep its receipt visible even
      // if the user selected another topic while the save was in flight.
      if (readExploreState(client).followReviews[review.topicID]?.outcome.state !== 'successful') {
        cancelExploreFollowReview(client, review.reviewID);
      }
    },
  };
}
export function exploreFollowPresentationModel(supplied: ExploreClientState, news?: NewsResponse, now = Date.now()) {
  const current = expireExploreState(supplied, now);
  const state = news ? reconcileExploreState(current, news.discovery.preferences.interests) : current;
  const active = state.activeFollowTopicID ? state.followReviews[state.activeFollowTopicID] : null;
  const selected = state.selectedTopicID ? state.followReviews[state.selectedTopicID] : null;
  const review = active ?? (selected?.outcome.state === 'successful' ? selected : null);
  if (!review) return null;
  const outcome = review.outcome;
  const blocked = outcome.state === 'obsolete' || outcome.state === 'expired' || outcome.state === 'uncertain';
  const message = outcome.state === 'successful' ? outcome.result.created ?
    `Now following “${outcome.result.interest.name}”.` : `Already following “${outcome.result.interest.name}”. The existing equivalent interest was kept.` :
    outcome.state === 'pending' ? 'Saving the approved interest… No search is started.' :
    outcome.state === 'expired' ? 'This review expired or its session is unavailable. Your draft is kept. Request new ideas explicitly; nothing retries automatically.' :
    outcome.state === 'obsolete' ? 'This review is obsolete because the source or session changed. Your draft is kept. Review a current topic explicitly.' :
    outcome.state === 'uncertain' ? 'The save outcome is unknown. Local status cannot recover follow receipts. Explicitly retry the original approved submission, without changes, to recover it safely.' :
    outcome.state === 'failed' && outcome.status === 409 ? 'The save conflicted with current state. Your draft is kept. Check local status before retrying explicitly.' :
    'Review every field before saving. Cancel changes no interests or preview results.';
  return { review, message, showEditor: outcome.state !== 'successful',
    editorDisabled: blocked || outcome.state === 'pending', canClose: outcome.state !== 'pending',
    retry: outcome.state === 'uncertain' && review.submittedDraft ?
      { topicID: review.topicID, reviewID: review.reviewID, draft: review.submittedDraft } : null,
    error: 'error' in outcome ? outcome.error : null,
    atCapacity: (news?.discovery.preferences.interests.length ?? 0) >= 12,
    needsRecovery: outcome.state === 'expired' || outcome.state === 'obsolete' || (outcome.state === 'failed' && outcome.status === 409),
    nextAction: outcome.state === 'successful' ? exploreFollowNextAction : null,
  };
}
function ExploreFollowReviewPanel({ state, news }: { state: ExploreClientState; news?: NewsResponse }) {
  const client = useQueryClient(), follow = useExploreFollow(), recover = useExploreRecovery();
  const [retryError, setRetryError] = useState<{ reviewID: string; error: Error } | null>(null);
  const model = exploreFollowPresentationModel(state, news);
  if (!model) return null;
  return <section className="panel explore-reading" aria-labelledby="explore-follow-title">
    <h2 id="explore-follow-title">Review &amp; follow · {model.review.draft.name}</h2>
    <p className="footnote">Following saves only the approved interest. It does not search, replace this preview or promote stories into your briefing.</p>
    <p role="status" aria-live="polite">{model.message}</p>
    <ErrorMessage error={model.error} />
    {model.showEditor && <>
      {model.atCapacity && <p role="status">You have 12 saved interests. An exactly equivalent interest can still be reused; otherwise <a className="text-link" href="#/news?view=discover">remove an interest in Discover</a> before saving. Your draft and preview are kept.</p>}
      <div className="editor explore-search-editor"><fieldset disabled={model.editorDisabled}>
        <legend>Editable new interest review</legend>
        <InterestEditor {...exploreFollowEditorProps(client, model.review, follow.mutateAsync)} />
      </fieldset></div>
      {model.retry && <div className="actions"><button type="button" className="button primary" onClick={() => {
        setRetryError(null);
        void follow.mutateAsync(model.retry!).catch(error => setRetryError({ reviewID: model.review.reviewID,
          error: error instanceof Error ? error : new Error('Could not recover this follow submission.') }));
      }}>Retry original approved follow</button><span className="footnote">Same submission identity · No search · No automatic retry</span></div>}
      {model.retry && <details><summary>Original approved interest to retry</summary>
        <p>{model.retry.draft.name} · {model.retry.draft.query}</p>
        <p className="footnote">{model.retry.draft.language} · {model.retry.draft.region} · {model.retry.draft.days} days · {model.retry.draft.intent} · {model.retry.draft.enabled ? 'Enabled' : 'Paused'}</p>
        <p className="footnote">Required groups: {model.retry.draft.requiredTerms.join('; ') || 'None'} · Exclusions: {model.retry.draft.excludedTerms.join('; ') || 'None'}</p>
      </details>}
      {model.needsRecovery && <div className="actions"><button type="button" className="button secondary" disabled={state.recovery.state === 'pending'}
        onClick={() => recover.mutate()}>Check local status</button><a className="text-link" href="#/news?view=discover">Manage saved interests in Discover</a></div>}
      {model.editorDisabled && <button type="button" className="button secondary" disabled={!model.canClose}
        onClick={() => cancelExploreFollowReview(client, model.review.reviewID)}>Close review · Keep draft</button>}
      {model.retry && <ErrorMessage error={retryError?.reviewID === model.review.reviewID ? retryError.error : null} />}
    </>}
    {model.nextAction && <><p>No coverage was fetched. Open Discover, choose the saved interest and explicitly Search when ready.</p>
      <div className="actions"><a className="button secondary" href={model.nextAction.href}>{model.nextAction.label}</a>
        {state.activeFollowTopicID === model.review.topicID && <button type="button" className="button secondary"
          onClick={() => cancelExploreFollowReview(client, model.review.reviewID)}>Close review</button>}</div></>}
  </section>;
}

/** Pure presentation only. Selection and every network command remain separate. */
export function exploreGalleryModel(state: ExploreClientState, news?: NewsResponse) {
  const interests = news?.discovery.preferences.interests ?? [];
  const enabled = interests.filter(interest => interest.enabled);
  const session = state.lifecycle.state === 'available' ? state.lifecycle.session : null;
  const cards = (session?.topics ?? []).slice(0, EXPLORE_MAX_TOPICS).map(topic => {
    const source = interests.find(interest => interest.id === topic.sourceInterestID &&
      interest.revision === topic.sourceInterestRevision && interest.enabled);
    return { ...topic, sourceLabel: source?.name ?? (news ? 'Source interest changed or unavailable' : 'Saved source interest (settings unavailable)'),
      selected: state.selectedTopicID === topic.id, selectable: topic.status === 'available' && (!news || !!source) };
  });
  const notices: string[] = [];
  if (cards.length && cards.length < EXPLORE_MAX_TOPICS) {
    notices.push(`Only ${cards.length} usable distinct ${cards.length === 1 ? 'idea was' : 'ideas were'} returned. No filler topics were added.`);
  }
  if (cards.some(card => !card.selectable)) notices.push('Some topics are obsolete because their source interests changed. Request new ideas explicitly; saved reading is unaffected.');
  if (state.lifecycle.state === 'obsolete') notices.push('This exploration is obsolete after interests changed or a workspace import. Request new ideas explicitly. Saved reading is unaffected.');
  if (state.lifecycle.state === 'expired') notices.push('This temporary exploration expired or is no longer available after a server restart. Check local status or request new ideas explicitly. Nothing reruns automatically.');
  if (state.generation.state === 'pending') notices.push('Finding new directions… Previous ideas remain visible while this request runs.');
  if (state.generation.state === 'failed' && cards.length) notices.push('The new request failed. Previous ideas are still here; nothing was followed or searched.');
  if (state.generation.state === 'uncertain') notices.push('The topic request outcome is unknown. Check local status before requesting more ideas; this does not repeat the PI request.');
  if (state.recovery.state === 'pending') notices.push('Checking local exploration status… No PI request or external news search.');
  const generationBlocked = state.generation.state === 'pending' || state.generation.state === 'uncertain';
  return { cards, notices, enabledNames: enabled.map(interest => interest.name),
    needsInterests: !!news && !enabled.length, needsPI: !!news && !news.ai.configured,
    canGenerate: !!news && !!enabled.length && news.ai.configured && !generationBlocked && state.recovery.state !== 'pending',
    canRecover: state.recovery.state !== 'pending',
    generationLabel: state.generation.state === 'pending' ? 'Suggesting topics…' : 'Suggest new topics · PI',
    generationError: state.generation.state === 'failed' ? state.generation.error.error : null,
    recoveryError: state.recovery.state === 'failed' ? state.recovery.error : null,
  };
}

export function ExplorePage() {
  const client = useQueryClient(), news = useNews(), state = useExploreState().data;
  const generate = useExploreGeneration(), recover = useExploreRecovery();
  const [reviewError, setReviewError] = useState<Error | null>(null);
  const model = exploreGalleryModel(state, news.data);
  const selectedCard = model.cards.find(card => card.selected);
  return <section className="news-explore" aria-labelledby="explore-title">
    <div className="panel">
      <header className="explore-intro">
        <div><p className="eyebrow">A LITTLE BEYOND YOUR USUAL READING</p>
          <h2 id="explore-title">Follow your curiosity.</h2>
          <p className="muted">New directions connected to what you already care about. Explore first. Follow only what stays interesting.</p>
        </div>
        <button type="button" className="button primary" disabled={!model.canGenerate}
          aria-describedby="explore-disclosure" onClick={() => generate.mutate()}>{model.generationLabel}</button>
      </header>
      <p id="explore-disclosure" className="explore-disclosure">Explicit PI action · Sends only enabled saved News interests — never your CV, workspace profile, notes or reading history. PI manages credentials; provider charges may apply. AI-suggested topics are ideas, not verified news or trends.</p>
      {news.data && model.enabledNames.length > 0 && <p className="footnote">Enabled starting points: {model.enabledNames.join(', ')}.</p>}
      {!news.data && news.isPending && <p role="status">Loading local News settings…</p>}
      <ErrorMessage error={news.error} />
      {model.needsInterests && <Empty title="Start with an interest" action={<a className="button secondary" href="#/news?view=discover">Manage interests in Discover</a>}>
        Enable a saved News interest to give suggestions a useful starting point. Your saved reading remains available.
      </Empty>}
      {model.needsPI && <div className="explore-setup">
        <h3>PI isn’t available</h3>
        <p>Set up PI to suggest topics. Standard search, feeds and saved reading still work without it.</p>
        <details><summary>PI setup details</summary>
          <p className="footnote">Install PI 1.0 or later, sign in with <code>/login</code> and save a default model with <code>/model</code> in PI. Availability does not guarantee provider authentication or access.</p>
          <p className="footnote">{news.data?.ai.model} · {news.data?.ai.message}</p>
          <a className="text-link" href="#/news?view=discover">Check PI connection in Discover</a>
        </details>
      </div>}
      <div className="explore-status" role="status" aria-live="polite">
        {model.notices.map(notice => <p key={notice}>{notice}</p>)}
      </div>
      <ErrorMessage error={model.generationError} />
      <ErrorMessage error={model.recoveryError} />
      <div className="actions"><button type="button" className="button secondary" disabled={!model.canRecover}
        onClick={() => recover.mutate()}>{state.recovery.state === 'pending' ? 'Checking local status…' : 'Check local status'}</button>
        <span className="footnote">Local recovery only — no generation or news search.</span></div>
    </div>
    {model.cards.length > 0 ? <section aria-labelledby="explore-ideas-title">
      <div className="section-title"><h2 id="explore-ideas-title" tabIndex={-1}>Directions to try</h2><Badge>{model.cards.length} AI-suggested topics</Badge></div>
      <p className="muted">Selecting a topic does not search, follow it or change your daily briefing.</p>
      <p className="sr-only" role="status" aria-live="polite">{selectedCard ?
        `Selected topic: ${selectedCard.title}. Review its search below; no news has been fetched by selecting it.` :
        'Choose a topic to review its search. Selecting does not fetch news.'}</p>
      <div className="explore-topic-grid">{model.cards.map(card => <article
        className={'panel explore-topic-card' + (card.selected ? ' selected' : '')} key={card.id}
        aria-labelledby={'explore-topic-' + card.id}>
        <Badge tone={card.selectable ? '' : 'warning'}>{card.selectable ? 'AI-suggested topic' : 'Obsolete topic'}</Badge>
        <h3 id={'explore-topic-' + card.id}>{card.title}</h3><p>{card.description}</p>
        <p className="explore-connection"><strong>Connected to: {card.sourceLabel}</strong><br />Suggested connection: {card.connection}</p>
        <button type="button" className={'button ' + (card.selected ? 'primary' : 'secondary')}
          aria-pressed={card.selected} aria-label={'Select topic: ' + card.title}
          aria-controls={state.selectedTopicID ? 'explore-preview' : undefined} disabled={!card.selectable}
          onClick={() => selectExploreTopic(client, card.id)}>{card.selected ? 'Selected topic' : 'Select topic'}</button>
      </article>)}</div>
    </section> : !model.needsInterests && <div className="panel"><Empty
      title={state.lifecycle.state === 'expired' ? 'Temporary session unavailable' : state.lifecycle.state === 'obsolete' ? 'Request a fresh direction' : 'No topic ideas yet'}>
      {state.generation.state === 'pending' ? 'PI is suggesting directions. Nothing is searched automatically.' : 'Request ideas when you’re ready, or check local status to recover a temporary session. Ideas are not guaranteed after a server restart.'}
    </Empty></div>}
    <ExploreReadingPreview state={state} news={news.data} onReview={topicID => {
      setReviewError(null);
      try { beginExploreFollowReview(client, topicID); }
      catch (error) { setReviewError(error instanceof Error ? error : new Error('Review the search or request a current topic before following.')); }
    }} />
    <ErrorMessage error={reviewError} />
    <ExploreFollowReviewPanel state={state} news={news.data} />
  </section>;
}
