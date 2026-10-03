import { useEffect, useState, type FormEvent } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Check, MapPin, Search, X } from 'lucide-react';
import { cityLabel, jobPreferencesSchema, workModes, employmentTypes, workModeLabels, employmentLabels, type City, type JobsResponse } from '../../../shared/jobs';
import { api } from '../../lib/api';
import { DraftConflict, ErrorMessage } from '../../components/ui';
import { useDraft } from '../../lib/draft';
import { useJobCommand } from './api';
import { JobSetupPanel } from './setup-panel';

export function PreferencesPanel({ state, busy, onDirty }: { state: JobsResponse; busy: boolean; onDirty: (dirty: boolean) => void }) {
  const command = useJobCommand();
  const form = useDraft(state.preferences, state.revision), draft = form.value;
  const [term, setTerm] = useState(''), [query, setQuery] = useState('');
  const [error, setError] = useState<unknown>(null), [saved, setSaved] = useState(false);
  const cities = useQuery<City[], Error>({ queryKey: ['job-cities', query], queryFn: ({ signal }) => api('/jobs/cities?q=' + encodeURIComponent(query), 'GET', undefined, { signal, timeoutMs: 15_000 }), enabled: query.length >= 2, retry: false, staleTime: 3600_000 });
  const pending = busy || command.isPending;
  useEffect(() => { onDirty(form.dirty || form.conflict); }, [form.dirty, form.conflict, onDirty]);
  function update(next: typeof draft) { form.edit(next); setSaved(false); }
  async function save(event: FormEvent) {
    event.preventDefault(); setError(null);
    if (form.conflict) return;
    const result = jobPreferencesSchema.safeParse(draft);
    if (!result.success) { setError(new Error('Choose at least one work arrangement and at most five cities.')); return; }
    try {
      const next = await command.mutateAsync({ path: '/preferences', method: 'PUT', body: { preferences: result.data, expectedRevision: form.revision } });
      form.accept(next.preferences, next.revision); setSaved(true);
    } catch { /* Retain the draft for a retry. */ }
  }
  function search() { if (term.trim().length >= 2) { if (query === term.trim()) void cities.refetch(); else setQuery(term.trim()); } }
  const dirty = form.dirty || form.conflict;
  const summary = [
    draft.workModes.map(mode => workModeLabels[mode]).join(', ') || 'Choose a work arrangement',
    draft.employmentTypes.length ? draft.employmentTypes.map(type => employmentLabels[type]).join(', ') : 'Any employment type',
    draft.cities.length ? draft.cities.map(city => `${city.name}, ${city.countryCode}`).join('; ') : 'Any location',
    `Past ${draft.days} days`,
  ].join(' · ');
  return <JobSetupPanel name="preferences" eyebrow="SEARCH PREFERENCES" title="Search filters" icon={<MapPin size={22} />}
    defaultExpanded={!state.profileConfirmed} summary={summary} status={dirty ? 'Unsaved changes' : undefined}
    feedback={<><ErrorMessage error={error ?? command.error} />{form.conflict && <DraftConflict
      onReload={() => { form.reload(); setSaved(false); command.reset(); }} onKeep={() => { form.keep(); setSaved(false); command.reset(); }}>
      <p>{state.preferences.workModes.map(mode => workModeLabels[mode]).join(', ')} · {state.preferences.employmentTypes.map(type => employmentLabels[type]).join(', ') || 'Any employment type'}</p>
      <p>{state.preferences.cities.map(cityLabel).join('; ') || 'Any location'} · Past {state.preferences.days} days</p>
    </DraftConflict>}</>}>
    <form onSubmit={event => void save(event)}>
    <fieldset disabled={pending}><legend>Where you work</legend><div className="job-options">{workModes.map(mode => <label className={'job-option' + (draft.workModes.includes(mode) ? ' selected' : '')} key={mode}><input type="checkbox" checked={draft.workModes.includes(mode)} onChange={event => update({ ...draft, workModes: event.target.checked ? [...draft.workModes, mode] : draft.workModes.filter(value => value !== mode) })} />{workModeLabels[mode]}</label>)}</div></fieldset>
    <fieldset disabled={pending}><legend>Employment type</legend><p className="footnote">Leave all unchecked to include any type.</p><div className="job-options">{employmentTypes.map(type => <label className={'job-option' + (draft.employmentTypes.includes(type) ? ' selected' : '')} key={type}><input type="checkbox" checked={draft.employmentTypes.includes(type)} onChange={event => update({ ...draft, employmentTypes: event.target.checked ? [...draft.employmentTypes, type] : draft.employmentTypes.filter(value => value !== type) })} />{employmentLabels[type]}</label>)}</div></fieldset>
    <fieldset disabled={pending}><legend>Your cities <span className="muted">({draft.cities.length}/5)</span></legend>
      <label htmlFor="job-city-search" className="sr-only">Find a city</label><div className="job-city-search"><input id="job-city-search" placeholder="Search a city, e.g. Tokyo, Japan" value={term} maxLength={100} onChange={event => { setTerm(event.target.value); if (event.target.value.trim() !== query) setQuery(''); }} onKeyDown={event => { if (event.key === 'Enter') { event.preventDefault(); search(); } }} /><button type="button" className="button secondary" disabled={term.trim().length < 2 || cities.isFetching} onClick={search}><Search size={16} />{cities.isFetching ? 'Finding…' : 'Find'}</button></div>
      {query && <div className="job-city-results" aria-live="polite">{cities.data?.map(city => <button type="button" key={city.id} disabled={draft.cities.length >= 5 || draft.cities.some(saved => saved.id === city.id)} onClick={() => { update({ ...draft, cities: [...draft.cities, city] }); setQuery(''); setTerm(''); }}><MapPin size={15} /><span>{cityLabel(city)}</span></button>)}{cities.data?.length === 0 && <p className="muted">No cities found. Try another spelling or add a country.</p>}</div>}
      <ErrorMessage error={cities.error} /><div className="job-city-chips">{draft.cities.map(city => <span key={city.id}>{cityLabel(city)}<button type="button" className="icon-button" aria-label={'Remove ' + cityLabel(city)} onClick={() => update({ ...draft, cities: draft.cities.filter(saved => saved.id !== city.id) })}><X size={13} /></button></span>)}</div>
      <p className="footnote">No cities means any location. Office and hybrid jobs must list a selected city and country. Remote jobs must explicitly allow a selected country or worldwide work; confirm eligibility with the employer.</p>
      <p className="footnote">City search works offline. Data from <a href="https://www.geonames.org/" target="_blank" rel="noreferrer">GeoNames</a> via <a href="https://github.com/lutangar/cities.json" target="_blank" rel="noreferrer">cities.json</a>, <a href="https://creativecommons.org/licenses/by/4.0/" target="_blank" rel="noreferrer">CC BY 4.0</a>.</p>
      <label>Posted within<select value={draft.days} onChange={event => update({ ...draft, days: Number(event.target.value) as 7 | 30 | 90 })}><option value={7}>7 days</option><option value={30}>30 days</option><option value={90}>90 days</option></select></label>
      <p className="footnote">Undated listings can appear with “Date not provided.” Specific filters exclude unstated employment types or work arrangements; selecting all arrangements also includes unspecified ones.</p>
    </fieldset>
    <div className="actions"><button className="button secondary" disabled={pending || form.conflict || !draft.workModes.length}>Save preferences</button>{saved && !dirty && <span className="success-text" role="status"><Check size={14} />Saved</span>}</div>
    </form>
  </JobSetupPanel>;
}
