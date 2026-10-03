import { useState, type FormEvent } from 'react';
import { Check, Pencil, UserRound } from 'lucide-react';
import { jobProfileLimits, jobProfileSchema, type JobProfile } from '../../../shared/jobs';
import { Badge, ErrorMessage } from '../../components/ui';
import { useJobCommand } from './api';
import { useWorkspace } from '../workspace/api';

const lines = (value: string) => value.split('\n').map(line => line.trim()).filter(Boolean);
export function ProfilePanel({ profile, revision, confirmed, busy, onDirty }: { profile: JobProfile; revision: string; confirmed: boolean; busy: boolean; onDirty: (dirty: boolean) => void }) {
  const command = useJobCommand(), [editing, setEditing] = useState(!confirmed);
  const workspace = useWorkspace();
  const [draft, setDraft] = useState(profile), [roles, setRoles] = useState(profile.roles.join('\n')), [skills, setSkills] = useState(profile.skills.join('\n')), [languages, setLanguages] = useState(profile.languages.join('\n'));
  const [error, setError] = useState<unknown>(null);
  const pending = busy || command.isPending;
  async function confirm(event: FormEvent) {
    event.preventDefault(); setError(null);
    const result = jobProfileSchema.safeParse({ ...draft, roles: lines(roles), skills: lines(skills), languages: lines(languages) });
    if (!result.success) { setError(new Error(result.error.issues.map(issue => issue.path.join('.') + ': ' + issue.message).join(' · '))); return; }
    try {
      await command.mutateAsync({ path: '/profile', method: 'PUT', body: { profile: result.data, expectedRevision: revision } });
      onDirty(false); setEditing(false);
    } catch { /* Keep edits visible. */ }
  }
  return <section className="panel job-profile"><div className="section-title"><div><p className="eyebrow">03 / YOUR PROFESSIONAL PROFILE</p><h2>{editing ? 'A profile, with your final say.' : profile.headline}</h2></div><Badge tone={confirmed ? 'success' : 'warning'}>{confirmed ? 'Reviewed' : 'Review needed'}</Badge></div>
    {editing ? <form className="editor" onSubmit={event => void confirm(event)}><p className="muted">Check the AI summary and correct anything it missed. Only this reviewed profile is used to match jobs. Confirming also saves your target roles to your workspace goals.</p>
      {!!workspace.data?.profile.targetRoles.length && <button type="button" className="text-link" disabled={pending} onClick={() => { setRoles(workspace.data!.profile.targetRoles.join('\n')); onDirty(true); }}>Use target roles from my workspace goals</button>}
      <fieldset className="job-profile-fields" disabled={pending}>
        <label>Professional headline<input required maxLength={200} value={draft.headline} onChange={event => { setDraft({ ...draft, headline: event.target.value }); onDirty(true); }} /></label>
        <label>Summary<textarea required rows={3} maxLength={1500} value={draft.summary} onChange={event => { setDraft({ ...draft, summary: event.target.value }); onDirty(true); }} /></label>
        <div className="form-grid"><label>Target roles <span className="muted">(one per line, up to {jobProfileLimits.roles})</span><textarea required rows={4} value={roles} onChange={event => { setRoles(event.target.value); onDirty(true); }} /></label><label>Primary skills <span className="muted">(one per line, up to {jobProfileLimits.skills})</span><textarea required rows={4} value={skills} onChange={event => { setSkills(event.target.value); onDirty(true); }} /></label></div>
        <label>Relevant experience<textarea rows={3} maxLength={1500} value={draft.experience} onChange={event => { setDraft({ ...draft, experience: event.target.value }); onDirty(true); }} /></label>
        <label>Languages <span className="muted">(one per line, up to {jobProfileLimits.languages})</span><textarea rows={2} value={languages} onChange={event => { setLanguages(event.target.value); onDirty(true); }} /></label>
      </fieldset><ErrorMessage error={error ?? command.error} /><button className="button primary" disabled={pending}><Check size={16} />Confirm profile</button>
    </form> : <><p className="muted">{profile.summary}</p><div className="job-skill-list">{profile.roles.map((role, index) => <Badge key={index}>{role}</Badge>)}</div><div className="job-skill-list">{profile.skills.map((skill, index) => <span key={index}>{skill}</span>)}</div>{profile.experience && <p className="footnote"><UserRound size={14} /> {profile.experience}</p>}{profile.languages.length > 0 && <p className="footnote">Languages: {profile.languages.join(', ')}</p>}<button className="text-link" disabled={pending} onClick={() => { setEditing(true); onDirty(true); }}><Pencil size={14} />Edit profile</button></>}
  </section>;
}
