import { useState } from 'react';
import { useIsMutating } from '@tanstack/react-query';
import { ArrowUpRight, BriefcaseBusiness, MapPin, RefreshCw, Search, Sparkles } from 'lucide-react';
import { workModeLabels, employmentLabels, type JobMatch, type JobsResponse } from '../../../shared/jobs';
import { Badge, Empty, ErrorMessage, Loading, OpenLink, PageHeader, formatDate } from '../../components/ui';
import { useJobs, useJobCommand } from './api';
import { CVPanel } from './cv';
import { PreferencesPanel } from './preferences';
import { ProfilePanel } from './profile';
import { JobTracker, SaveJob } from './tracker';
import { useWorkspace } from '../workspace/api';
import { dayKey } from '../../../shared/dates';

function JobCard({ job, compact = false }: { job: JobMatch; compact?: boolean }) {
  return <article className={'job-card' + (compact ? ' compact' : '')}>
    <div className="row-spread"><span className="eyebrow break-word">{job.company}</span><Badge>Retrieved offer</Badge></div>
    <h3><a href={job.url} target="_blank" rel="noreferrer">{job.title}<ArrowUpRight size={17} /></a></h3>
    <p className="job-location"><MapPin size={14} />{job.location}</p>
    <div className="job-skill-list"><Badge>{job.workMode === 'unknown' ? 'Work arrangement not stated' : workModeLabels[job.workMode]}</Badge>{job.employmentTypes.map(type => <Badge key={type}>{employmentLabels[type]}</Badge>)}</div>
    <p className="match-reason">{job.reason}</p>
    {!compact && <>{job.salary && <p className="job-salary">{job.salary}</p>}{job.gaps.length > 0 && <div className="job-gaps"><strong>Not evidenced in your profile or needing confirmation</strong><ul>{job.gaps.map((gap, index) => <li key={index}>{gap}</li>)}</ul></div>}
      <details className="job-description"><summary>Read retrieved description</summary><p>{job.description || 'The source did not provide a description.'}</p></details></>}
    <div className="job-card-footer"><span>{job.source} · {job.publishedAt ? formatDate(job.publishedAt) : 'Date not provided'}</span><a className="text-link" href={job.url} target="_blank" rel="noreferrer">View offer<ArrowUpRight size={14} /></a></div>
    {!compact && <p className="footnote">Estimated fit: {job.score}%. Use the reasons and source details to assess the opportunity.</p>}<SaveJob matchID={job.id} url={job.url} />
  </article>;
}
function JobWorkspace({ state, refresh }: { state: JobsResponse; refresh: () => void }) {
  const search = useJobCommand();
  const activeCommands = useIsMutating({ mutationKey: ['jobs-command'] });
  const [dirtyPreferences, setDirtyPreferences] = useState(false), [dirtyProfile, setDirtyProfile] = useState(false);
  const busy = !!state.activity || activeCommands > 0, dirty = dirtyPreferences || dirtyProfile;
  const ready = !!state.cv && state.profileConfirmed && !dirty && state.ai.configured;
  const stage = !state.cv ? 0 : !state.profile || !state.profileConfirmed ? 1 : 2;
  const completedSearch = state.lastSearch?.completedAt && !state.lastSearch.error ? state.lastSearch : null;
  const emptyTitle = busy ? 'Looking for your next opportunity…' : !completedSearch ? 'Your next chapter starts here.' :
    completedSearch.sourceCount ? 'No strong matches this time.' : 'No listings found for these filters.';
  const emptyDescription = !completedSearch ? 'Your matched offers will appear here after you review your profile and run a search.' :
    completedSearch.sourceCount ? `None of the ${completedSearch.sourceCount} retrieved listings was a strong match for your reviewed profile. Try more cities or a longer date window.` :
      'The sources did not return readable listings matching your filters. Try more cities, broader work arrangements, or a longer date window.';
  return <>
    <ol className="job-steps" aria-label="Job matching steps">{['Upload your CV', 'Review your profile', 'Find your next role'].map((step, index) => <li key={step} className={index <= stage ? 'active' : ''} aria-current={index === stage ? 'step' : undefined}><span>0{index + 1}</span>{step}</li>)}</ol>
    <div className="job-connection"><div><Sparkles size={18} /><span><strong>{state.ai.configured ? 'PI available' : 'Connect PI to analyze and match'}</strong><small>{state.ai.model} · {state.ai.message}</small></span></div><button className="icon-button" aria-label="Refresh PI connection" onClick={refresh}><RefreshCw size={16} /></button></div>
    {!state.ai.configured && <p className="footnote">Install PI 1.0 or later, sign in with <code>/login</code>, select a model with <code>/model</code> and save it as the default in PI. Then refresh the connection above.</p>}
    {state.activity && <p className="job-progress" role="status" aria-live="polite"><Sparkles size={16} className="spin" />{state.activity === 'uploading' ? 'Reading your CV…' : state.activity === 'analyzing' ? 'Preparing your professional profile… This can take up to two minutes.' : 'PI is searching the web, checking listings and assessing your fit… This can take up to three minutes.'} You can leave this section while it works.</p>}
    <div className="job-setup-grid"><CVPanel state={state} busy={busy || dirty} /><PreferencesPanel state={state} busy={busy} onDirty={setDirtyPreferences} /></div>
    {state.profile && <ProfilePanel profile={state.profile} revision={state.revision} confirmed={state.profileConfirmed} busy={busy} onDirty={setDirtyProfile} />}
    <section className="panel job-results"><div className="section-title"><div><p className="eyebrow">YOUR NEXT MOVE</p><h2>Offers that fit your experience.</h2></div><button className="button primary" disabled={busy || !ready} onClick={() => search.mutate({ path: '/search', body: { expectedRevision: state.revision } })}><Search size={16} />{busy && state.activity === 'searching' ? 'Searching…' : 'Find matching jobs'}</button></div>
      <p className="muted">{dirty ? 'Save your preferences and confirm your profile edits before searching.' : !state.cv ? 'Upload a CV, choose your preferences, then analyze and review your profile.' : !state.profileConfirmed ? 'Analyze your CV and confirm the profile above to unlock your job search.' : 'Search with your reviewed profile and saved preferences. Every match links to a retrieved listing.'}</p>
      <p className="footnote">Search checks relevant job boards and uses PI web search with your reviewed roles, skills and saved filters. PI then ranks retrieved listings against your profile. Bing and DuckDuckGo provide additional search when needed. Your PI provider’s usage limits or billing apply. CV text is used only for analysis. No applications are sent.</p>
      <ErrorMessage error={search.error ?? state.lastSearch?.error} />
      {state.lastSearch?.warnings.map(warning => <p key={warning} className="footnote warning-text">{warning}</p>)}
      {state.matches.length ? <div className="job-results-grid">{state.matches.map(job => <JobCard key={job.id} job={job} />)}</div> : <Empty title={emptyTitle}>{emptyDescription}</Empty>}
      {state.lastSearch?.completedAt && <p className="footnote">Last successful search: {new Date(state.lastSearch.completedAt).toLocaleString()} · {state.lastSearch.sourceCount} listings assessed · {state.matches.length} matches. Saved matches can become outdated.</p>}
      <p className="footnote">Sources: PI web search, <a href="https://www.tokyodev.com/jobs" target="_blank" rel="noreferrer">TokyoDev</a> (software jobs in Japan), <a href="https://reteinformaticalavoro.it/offerte-di-lavoro/milano" target="_blank" rel="noreferrer">Reteinformaticalavoro</a> (software jobs in Milan), <a href="https://www.arbeitnow.com/" target="_blank" rel="noreferrer">Arbeitnow</a> (mainly Germany), and <a href="https://remotive.com/" target="_blank" rel="noreferrer">Remotive</a> (remote listings, delayed by 24 hours). Bing and DuckDuckGo provide fallback search. Every offer is retrieved from its source before ranking. Job-board responses are cached locally while the server runs. Coverage is limited; scores are estimates. Check availability, location restrictions and work authorization at the source.</p>
    </section>
  </>;
}
export function JobsPage() {
  const query = useJobs();
  const [view, setView] = useState(new URLSearchParams(window.location.hash.split('?')[1]).get('view') === 'tracker' ? 'tracker' : 'matches');
  return <><PageHeader eyebrow="YOUR NEXT OPPORTUNITY" title="Jobs" description="Find relevant roles, keep a shortlist, and prepare your next move." />
    <div className="tabs library-tabs"><button className={view === 'matches' ? 'active' : ''} aria-pressed={view === 'matches'} onClick={() => setView('matches')}>Find opportunities</button><button className={view === 'tracker' ? 'active' : ''} aria-pressed={view === 'tracker'} onClick={() => setView('tracker')}>Applications & preparation</button></div>
    {view === 'tracker' ? <JobTracker /> : query.isPending ? <Loading /> : query.data ? <><ErrorMessage error={query.error} /><JobWorkspace state={query.data} refresh={() => void query.refetch()} /></> : <ErrorMessage error={query.error} />}
  </>;
}
export function JobsWidget() {
  const query = useJobs(), workspace = useWorkspace();
  if (query.isPending) return <Loading />;
  if (!query.data) return <ErrorMessage error={query.error} />;
  const state = query.data;
  const due = workspace.data?.jobs.filter(j => j.followUpOn && j.followUpOn <= dayKey() && !['archived', 'offer'].includes(j.stage)) ?? [];
  return <><div className="widget-summary"><strong>{String(state.matches.length).padStart(2, '0')}</strong><span>matched opportunities</span><Badge>{state.activity ? 'Working…' : state.profileConfirmed ? 'Profile ready' : 'Set up your profile'}</Badge></div>
    {state.matches.length ? <div className="job-results-grid">{state.matches.slice(0, 2).map(job => <JobCard job={job} compact key={job.id} />)}</div> : <Empty title={state.profileConfirmed ? 'Ready for your next move.' : 'Find work that fits you.'}>{state.profileConfirmed ? 'Open Jobs to search with your profile and preferences.' : 'Upload your CV and choose how and where you want to work.'}</Empty>}
    <div className="reading-actions"><OpenLink route="jobs"><BriefcaseBusiness size={14} />{state.profileConfirmed ? 'Explore job matches' : 'Set up job matching'}</OpenLink><a className="text-link" href="#/jobs?view=tracker">{workspace.data?.jobs.length ?? 0} saved applications →</a>{due.length > 0 && <a className="text-link" href="#/jobs?view=tracker&due=1">{due.length} follow-ups due →</a>}</div><ErrorMessage error={workspace.error} /></>;
}
