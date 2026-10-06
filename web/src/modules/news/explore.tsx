import { useQueryClient } from '@tanstack/react-query';
import { Badge, Empty, ErrorMessage } from '../../components/ui';
import { EXPLORE_MAX_TOPICS } from '../../../shared/news-explore';
import type { NewsResponse } from '../../../shared/news';
import { useNews } from './api';
import { selectExploreTopic, useExploreGeneration, useExploreRecovery, useExploreState } from './explore-api';
import type { ExploreClientState } from './explore-state';
import { ExploreReadingPreview } from './explore-preview';

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
  const model = exploreGalleryModel(state, news.data);
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
      <div className="explore-topic-grid">{model.cards.map(card => <article
        className={'panel explore-topic-card' + (card.selected ? ' selected' : '')} key={card.id}>
        <Badge tone={card.selectable ? '' : 'warning'}>{card.selectable ? 'AI-suggested topic' : 'Obsolete topic'}</Badge>
        <h3>{card.title}</h3><p>{card.description}</p>
        <p className="explore-connection"><strong>Connected to: {card.sourceLabel}</strong><br />Suggested connection: {card.connection}</p>
        <button type="button" className={'button ' + (card.selected ? 'primary' : 'secondary')}
          aria-pressed={card.selected} aria-label={'Select topic: ' + card.title} disabled={!card.selectable}
          onClick={() => selectExploreTopic(client, card.id)}>{card.selected ? 'Selected topic' : 'Select topic'}</button>
      </article>)}</div>
    </section> : !model.needsInterests && <div className="panel"><Empty
      title={state.lifecycle.state === 'expired' ? 'Temporary session unavailable' : state.lifecycle.state === 'obsolete' ? 'Request a fresh direction' : 'No topic ideas yet'}>
      {state.generation.state === 'pending' ? 'PI is suggesting directions. Nothing is searched automatically.' : 'Request ideas when you’re ready, or check local status to recover a temporary session. Ideas are not guaranteed after a server restart.'}
    </Empty></div>}
    <ExploreReadingPreview state={state} news={news.data} />
  </section>;
}
