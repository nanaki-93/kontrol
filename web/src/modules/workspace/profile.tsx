import { useState, type FormEvent } from 'react';
import { learningPaths, type WorkspaceProfile } from '../../../shared/workspace';
import { useLearning } from '../learning/api';
import { Badge, ErrorMessage, Loading } from '../../components/ui';
import { useWorkspace, useWorkspaceCommand } from './api';

function ProfileForm({ profile }: { profile: WorkspaceProfile }) {
  const command = useWorkspaceCommand(), learning = useLearning();
  const [draft, setDraft] = useState(profile), [baseline, setBaseline] = useState(profile);
  const [roles, setRoles] = useState(profile.targetRoles.join('\n')), [interests, setInterests] = useState(profile.interests.join('\n'));
  const [zones, setZones] = useState(profile.timeZones.map(z => z.label + ' | ' + z.zone).join('\n'));
  const [saved, setSaved] = useState(false);
  const lines = (value: string) => value.split('\n').map(v => v.trim()).filter(Boolean);
  async function submit(event: FormEvent) {
    event.preventDefault(); setSaved(false);
    const profile = { ...draft, targetRoles: lines(roles), interests: lines(interests), timeZones: lines(zones).map(line => {
      const [label, zone] = line.split('|').map(v => v.trim()); return { label, zone: zone ?? label };
    }) };
    try {
      const next = await command.mutateAsync({ path: '/profile', method: 'PUT', body: { profile, expectedProfile: baseline } });
      setBaseline(next.profile); setSaved(true);
    } catch { /* Keep every field available for correction. */ }
  }
  return <form className="panel editor" onSubmit={event => void submit(event)} onChange={() => setSaved(false)}>
    <div className="section-title"><h2>Your goals and interests</h2><Badge>Shared across your workspace</Badge></div>
    <label>What are you working toward?<input maxLength={500} value={draft.goal} onChange={e => setDraft({ ...draft, goal: e.target.value })} placeholder="Build confidence for my next backend role" /></label>
    <div className="form-grid"><label>Target roles · up to five, one per line<textarea rows={3} value={roles} onChange={e => setRoles(e.target.value)} placeholder="Backend engineer" /></label>
      <label>Interests · up to twelve, one per line<textarea rows={3} value={interests} onChange={e => setInterests(e.target.value)} placeholder="Go\nDistributed systems" /></label></div>
    <p className="footnote">Interests prioritize your briefing. Target roles are available when reviewing your CV profile; you confirm changes before job searches use them.</p>
    <div className="form-grid"><label>Learning path<select value={draft.pathID ?? ''} onChange={e => setDraft({ ...draft, pathID: (e.target.value || null) as WorkspaceProfile['pathID'] })}><option value="">Explore at my own pace</option>{learningPaths.map(p => <option key={p.id} value={p.id}>{p.title}</option>)}</select></label>
      <label>Weekly lesson target<input type="number" min={1} max={14} required value={draft.weeklyTarget} onChange={e => setDraft({ ...draft, weeklyTarget: Number(e.target.value) })} /></label></div>
    <fieldset className="topic-selector"><legend>Preferred learning topics</legend>{learning.data?.topics.map(t => <label className="checkbox-label" key={t.id}><input type="checkbox" checked={draft.topicIDs.includes(t.id)} onChange={e => setDraft({ ...draft, topicIDs: e.target.checked ? [...draft.topicIDs, t.id] : draft.topicIDs.filter(id => id !== t.id) })} />{t.name}</label>)}</fieldset>
    <label>World clocks · up to three, “Label | Time zone” per line<textarea rows={3} value={zones} onChange={e => setZones(e.target.value)} placeholder={'Tokyo | Asia/Tokyo\nBerlin | Europe/Berlin'} /></label>
    <ErrorMessage error={command.error} /><div className="actions"><button className="button primary" disabled={command.isPending}>Save goals</button>{saved && <span className="success-text" role="status">Goals saved</span>}
      {command.error && <button type="button" className="button secondary" onClick={() => { setBaseline(profile); command.reset(); }}>Keep my draft for the next save</button>}</div>
    {command.error && <details><summary>Review the currently saved goals</summary><p>{profile.goal || 'No goal set'}</p><p>Target roles: {profile.targetRoles.join(', ') || 'None'}</p><p>Interests: {profile.interests.join(', ') || 'None'}</p><p>Learning path: {learningPaths.find(p => p.id === profile.pathID)?.title ?? 'Explore at my own pace'} · {profile.weeklyTarget} lessons per week</p></details>}
  </form>;
}
export function ProfileSettings() {
  const query = useWorkspace();
  return query.data ? <ProfileForm profile={query.data.profile} /> : query.isPending ? <Loading /> : <ErrorMessage error={query.error} />;
}
