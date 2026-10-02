import { useEffect, useState } from 'react';
import { useIsMutating } from '@tanstack/react-query';
import { ArrowUpRight, BriefcaseBusiness, MapPin, RefreshCw, Search, Sparkles } from 'lucide-react';
import { workModeLabels, employmentLabels, type JobMatch, type JobsResponse } from '../../../shared/jobs';
import { Badge, Empty, ErrorMessage, Loading, OpenLink, PageHeader, formatDate } from '../../components/ui';
import { useJobs, useJobCommand } from './api';
import { CVPanel } from './cv';
import { PreferencesPanel } from './preferences';
import { ProfilePanel } from './profile';

function JobCard({ job, compact = false }: { job: JobMatch; compact?: boolean }) {
  return <article className={'job-card' + (compact ? ' compact' : '')}>
    <div className="row-spread"><span className="eyebrow break-word">{job.company}</span><Badge tone="success">{job.score}% estimated fit</Badge></div>
    <h3><a href={job.url} target="_blank" rel="noreferrer">{job.title}<ArrowUpRight size={17} /></a></h3>
    <p className="job-location"><MapPin size={14} />{job.location}</p>
    <div className="job-skill-list"><Badge>{job.workMode === 'unknown' ? 'Work arrangement not stated' : workModeLabels[job.workMode]}</Badge>{job.employmentTypes.map(type => <Badge key={type}>{employmentLabels[type]}</Badge>)}</div>
    <p className="match-reason">{job.reason}</p>
    {!compact && <>{job.salary && <p className="job-salary">{job.salary}</p>}{job.gaps.length > 0 && <div className="job-gaps"><strong>Things to check</strong><ul>{job.gaps.map((gap, index) => <li key={index}>{gap}</li>)}</ul></div>}
      <details className="job-description"><summary>Read retrieved description</summary><p>{job.description || 'The source did not provide a description.'}</p></details></>}
    <div className="job-card-footer"><span>{job.source} · {job.publishedAt ? formatDate(job.publishedAt) : 'Date not provided'}</span><a className="text-link" href={job.url} target="_blank" rel="noreferrer">View offer<ArrowUpRight size={14} /></a></div>
  </article>;
}
function JobWorkspace({ state, refresh }: { state: JobsResponse; refresh: () => void }) {
  const search = useJobCommand();
  const activeCommands = useIsMutating({ mutationKey: ['jobs-command'] });
  const [dirtyPreferences, setDirtyPreferences] = useState(false), [dirtyProfile, setDirtyProfile] = useState(false);
  const savedPreferences = JSON.stringify(state.preferences), savedProfile = JSON.stringify(state.profile) + state.profileConfirmed;
  useEffect(() => setDirtyPreferences(false), [savedPreferences]);
  useEffect(() => setDirtyProfile(false), [savedProfile]);
  const busy = !!state.activity || activeCommands > 0, dirty = dirtyPreferences || dirtyProfile;
  const ready = !!state.cv && state.profileConfirmed && !dirty && state.ai.configured;
  const stage = !state.cv ? 0 : !state.profile || !state.profileConfirmed ? 1 : 2;
  return <>
    <ol className="job-steps" aria-label="Job matching steps">{['Upload your CV', 'Review your profile', 'Find your next role'].map((step, index) => <li key={step} className={index <= stage ? 'active' : ''} aria-current={index === stage ? 'step' : undefined}><span>0{index + 1}</span>{step}</li>)}</ol>
    <div className="job-connection"><div><Sparkles size={18} /><span><strong>{state.ai.configured ? 'PI available' : 'Connect PI to analyze and match'}</strong><small>{state.ai.model} · {state.ai.message}</small></span></div><button className="icon-button" aria-label="Refresh PI connection" onClick={refresh}><RefreshCw size={16} /></button></div>
    {!state.ai.configured && <p className="footnote">Install PI 1.0 or later, sign in with <code>/login</code>, select a model with <code>/model</code> and save it as the default in PI. Then refresh the connection above.</p>}
    {state.activity && <p className="job-progress" role="status" aria-live="polite"><Sparkles size={16} className="spin" />{state.activity === 'uploading' ? 'Reading your CV…' : state.activity === 'analyzing' ? 'Preparing your professional profile… This can take up to two minutes.' : 'Searching listings and assessing your fit…'} You can leave this section while it works.</p>}
    <div className="job-setup-grid"><CVPanel state={state} busy={busy || dirty} /><PreferencesPanel key={JSON.stringify(state.preferences)} state={state} busy={busy} onDirty={setDirtyPreferences} /></div>
    {state.profile && <ProfilePanel key={JSON.stringify(state.profile) + state.profileConfirmed} profile={state.profile} revision={state.revision} confirmed={state.profileConfirmed} busy={busy} onDirty={setDirtyProfile} />}
    <section className="panel job-results"><div className="section-title"><div><p className="eyebrow">YOUR NEXT MOVE</p><h2>Offers that fit your experience.</h2></div><button className="button primary" disabled={busy || !ready} onClick={() => search.mutate({ path: '/search', body: { expectedRevision: state.revision } })}><Search size={16} />{busy && state.activity === 'searching' ? 'Searching…' : 'Find matching jobs'}</button></div>
      <p className="muted">{dirty ? 'Save your preferences and confirm your profile edits before searching.' : !state.cv ? 'Upload a CV, choose your preferences, then analyze and review your profile.' : !state.profileConfirmed ? 'Analyze your CV and confirm the profile above to unlock your job search.' : 'Search with your reviewed profile and saved preferences. Every match links to a retrieved listing.'}</p>
      <p className="footnote">Search sends role titles, selected cities and filters to Bing, and your reviewed profile plus retrieved job descriptions to your PI provider. Provider usage limits or billing apply. CV text is used only for analysis. No applications are sent.</p>
      <ErrorMessage error={search.error ?? state.lastSearch?.error} />
      {state.lastSearch?.warnings.map(warning => <p key={warning} className="footnote warning-text">{warning}</p>)}
      {state.matches.length ? <div className="job-results-grid">{state.matches.map(job => <JobCard key={job.id} job={job} />)}</div> : <Empty title={busy ? 'Looking for your next opportunity…' : state.lastSearch?.completedAt && !state.lastSearch.error ? 'No strong matches this time.' : 'Your next chapter starts here.'}>
        {state.lastSearch?.completedAt && !state.lastSearch.error ? 'Try more cities, broader work arrangements, or a longer date window. Some sites do not expose readable job listings.' : 'Your matched offers will appear here after you review your profile and run a search.'}
      </Empty>}
      {state.lastSearch?.completedAt && <p className="footnote">Last successful search: {new Date(state.lastSearch.completedAt).toLocaleString()} · {state.lastSearch.sourceCount} listings assessed · {state.matches.length} matches. Saved matches can become outdated.</p>}
      <p className="footnote">Sources: accessible job pages found through Bing, <a href="https://www.arbeitnow.com/" target="_blank" rel="noreferrer">Arbeitnow</a> (mainly Germany), and <a href="https://remotive.com/" target="_blank" rel="noreferrer">Remotive</a> (remote listings, delayed by 24 hours). Job-board responses are cached locally while the server runs. Coverage is limited; scores are estimates. Check availability, location restrictions and work authorization at the source.</p>
    </section>
  </>;
}
export function JobsPage() {
  const query = useJobs();
  return <><PageHeader eyebrow="A CAREER THAT FITS YOUR LIFE" title="JOB" description="Your experience. Your preferences. A more personal job search." />
    {query.isPending ? <Loading /> : query.data ? <><ErrorMessage error={query.error} /><JobWorkspace state={query.data} refresh={() => void query.refetch()} /></> : <ErrorMessage error={query.error} />}
  </>;
}
export function JobsWidget() {
  const query = useJobs();
  if (query.isPending) return <Loading />;
  if (!query.data) return <ErrorMessage error={query.error} />;
  const state = query.data;
  return <><div className="widget-summary"><strong>{String(state.matches.length).padStart(2, '0')}</strong><span>matched opportunities</span><Badge>{state.activity ? 'Working…' : state.profileConfirmed ? 'Profile ready' : 'Set up your profile'}</Badge></div>
    {state.matches.length ? <div className="job-results-grid">{state.matches.slice(0, 2).map(job => <JobCard job={job} compact key={job.id} />)}</div> : <Empty title={state.profileConfirmed ? 'Ready for your next move.' : 'Find work that fits you.'}>{state.profileConfirmed ? 'Open JOB to search with your profile and preferences.' : 'Upload your CV and choose how and where you want to work.'}</Empty>}
    <OpenLink route="jobs"><BriefcaseBusiness size={14} />{state.profileConfirmed ? 'Explore job matches' : 'Set up JOB'}</OpenLink></>;
}
