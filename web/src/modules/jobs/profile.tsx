import { useEffect, useState, type FormEvent } from 'react';
import { Check, Pencil, UserRound } from 'lucide-react';
import { jobProfileLimits, jobProfileSchema, type JobProfile } from '../../../shared/jobs';
import { Badge, DraftConflict, ErrorMessage } from '../../components/ui';
import { useJobCommand } from './api';
import { useDraft } from '../../lib/draft';
import { useWorkspace } from '../workspace/api';

const lines = (value: string) => value.split('\n').map(line => line.trim()).filter(Boolean);
const fields = (profile: JobProfile) => ({ ...profile, roles: profile.roles.join('\n'), skills: profile.skills.join('\n'), languages: profile.languages.join('\n') });
export function ProfilePanel({ profile, revision, confirmed, busy, onDirty }: { profile: JobProfile; revision: string; confirmed: boolean; busy: boolean; onDirty: (dirty: boolean) => void }) {
  const command = useJobCommand(), [editing, setEditing] = useState(!confirmed);
  const workspace = useWorkspace();
  const form = useDraft(fields(profile), revision), draft = form.value;
  const setDraft = form.edit;
  useEffect(() => { onDirty(form.dirty || form.conflict); }, [form.dirty, form.conflict, onDirty]);
  useEffect(() => () => onDirty(false), [onDirty]);
  useEffect(() => { if (!confirmed) setEditing(true); }, [confirmed]);
  const [error, setError] = useState<unknown>(null);
  const pending = busy || command.isPending;
  async function confirm(event: FormEvent) {
    event.preventDefault(); setError(null);
    if (form.conflict) return;
    const result = jobProfileSchema.safeParse({ ...draft, roles: lines(draft.roles), skills: lines(draft.skills), languages: lines(draft.languages) });
    if (!result.success) { setError(new Error(result.error.issues.map(issue => issue.path.join('.') + ': ' + issue.message).join(' · '))); return; }
    try {
      const next = await command.mutateAsync({ path: '/profile', method: 'PUT', body: { profile: result.data, expectedRevision: form.revision } });
      form.accept(fields(next.profile!), next.revision); setEditing(false);
    } catch { /* Keep edits visible. */ }
  }
  return <section className="panel job-profile"><div className="section-title"><div><p className="eyebrow">03 / YOUR PROFESSIONAL PROFILE</p><h2>{editing ? 'A profile, with your final say.' : profile.headline}</h2></div><Badge tone={confirmed ? 'success' : 'warning'}>{confirmed ? 'Reviewed' : 'Review needed'}</Badge></div>
    {editing ? <form className="editor" onSubmit={event => void confirm(event)}><p className="muted">Check the AI summary and correct anything it missed. Only this reviewed profile is used to match jobs. Confirming also saves your target roles to your workspace goals.</p>
      {!!workspace.data?.profile.targetRoles.length && <button type="button" className="text-link" disabled={pending} onClick={() => { setDraft({ ...draft, roles: workspace.data!.profile.targetRoles.join('\n') }); }}>Use target roles from my workspace goals</button>}
      <fieldset className="job-profile-fields" disabled={pending}>
        <label>Professional headline<input required maxLength={200} value={draft.headline} onChange={event => { setDraft({ ...draft, headline: event.target.value }); }} /></label>
        <label>Summary<textarea required rows={3} maxLength={1500} value={draft.summary} onChange={event => { setDraft({ ...draft, summary: event.target.value }); }} /></label>
        <div className="form-grid"><label>Target roles <span className="muted">(one per line, up to {jobProfileLimits.roles})</span><textarea required rows={4} value={draft.roles} onChange={event => { setDraft({ ...draft, roles: event.target.value }); }} /></label><label>Primary skills <span className="muted">(one per line, up to {jobProfileLimits.skills})</span><textarea required rows={4} value={draft.skills} onChange={event => { setDraft({ ...draft, skills: event.target.value }); }} /></label></div>
        <label>Relevant experience<textarea rows={3} maxLength={1500} value={draft.experience} onChange={event => { setDraft({ ...draft, experience: event.target.value }); }} /></label>
        <label>Languages <span className="muted">(one per line, up to {jobProfileLimits.languages})</span><textarea rows={2} value={draft.languages} onChange={event => { setDraft({ ...draft, languages: event.target.value }); }} /></label>
      </fieldset>{form.conflict && <DraftConflict onReload={() => { form.reload(); command.reset(); }} onKeep={() => { form.keep(); command.reset(); }}>
        <h3>{profile.headline}</h3><p>{profile.summary}</p><p>Roles: {profile.roles.join(', ')}</p><p>Skills: {profile.skills.join(', ')}</p><p>{profile.experience}</p><p>Languages: {profile.languages.join(', ') || 'None'}</p>
      </DraftConflict>}<ErrorMessage error={error ?? command.error} /><button className="button primary" disabled={pending || form.conflict}><Check size={16} />Confirm profile</button>
    </form> : <><p className="muted">{profile.summary}</p><div className="job-skill-list">{profile.roles.map((role, index) => <Badge key={index}>{role}</Badge>)}</div><div className="job-skill-list">{profile.skills.map((skill, index) => <span key={index}>{skill}</span>)}</div>{profile.experience && <p className="footnote"><UserRound size={14} /> {profile.experience}</p>}{profile.languages.length > 0 && <p className="footnote">Languages: {profile.languages.join(', ')}</p>}<button className="text-link" disabled={pending} onClick={() => { setEditing(true); }}><Pencil size={14} />Edit profile</button></>}
  </section>;
}
