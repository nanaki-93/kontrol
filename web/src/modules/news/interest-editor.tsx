import { useId, useState, type FormEvent } from 'react';
import { Plus } from 'lucide-react';
import { interestDraftSchema, type InterestDraft, type NewsInterest } from '../../../shared/news';
import { useCommand } from '../../lib/api';
import { ErrorMessage } from '../../components/ui';

const blank: InterestDraft = { name: '', query: '', language: 'en', region: 'US', days: 7,
  intent: 'news', requiredTerms: [], excludedTerms: [], enabled: true };
const lines = (value: string) => value.split('\n').map(t => t.trim()).filter(Boolean);

export interface InterestEditorSaveResult { interest: NewsInterest; created: boolean }
type CreateInterest = (draft: InterestDraft) => Promise<InterestEditorSaveResult>;
export type InterestEditorInput =
  | { interest: NewsInterest; initialDraft?: never; onCreate?: never }
  | { interest?: never; initialDraft?: InterestDraft; onCreate?: CreateInterest };
export type InterestEditorProps = InterestEditorInput & {
  // A new suggestion/review identity remounts creation; refreshed metadata does not.
  editorID?: string;
  headingLevel?: 2 | 3;
  onClose: () => void;
  onSaved?: (result: InterestEditorSaveResult) => void;
};
interface EditorState { draft: InterestDraft; existing: Pick<NewsInterest, 'id' | 'revision'> | null }
type InterestCommand = { path: string; method: 'POST' | 'PUT'; body: InterestDraft & { expectedRevision?: string } };

export function interestEditorIdentity(input: InterestEditorInput, editorID = 'new'): string {
  return input.interest ? 'edit:' + input.interest.id : 'create:' + editorID;
}
export function createInterestEditorState(input: InterestEditorInput): EditorState {
  if (input.interest && (input.initialDraft || input.onCreate)) throw new Error('Editing and creation inputs cannot be combined.');
  const value = input.interest ?? input.initialDraft ?? blank;
  // Do not validate on opening: legacy short queries must remain editable.
  // Copy only draft fields, never IDs/revisions or caller-owned filter arrays.
  return { existing: input.interest ? { id: input.interest.id, revision: input.interest.revision } : null,
    draft: { name: value.name, query: value.query, language: value.language, region: value.region, days: value.days,
      intent: value.intent, requiredTerms: [...value.requiredTerms], excludedTerms: [...value.excludedTerms], enabled: value.enabled } };
}
export function validateInterestEditorDraft(draft: InterestDraft, required: string, excluded: string) {
  return interestDraftSchema.safeParse({ ...draft, requiredTerms: lines(required), excludedTerms: lines(excluded) });
}
export async function saveInterestEditor(state: EditorState, draft: InterestDraft,
  execute: (command: InterestCommand) => Promise<NewsInterest>, onCreate?: CreateInterest): Promise<InterestEditorSaveResult> {
  const validated = interestDraftSchema.parse(draft);
  if (!state.existing && onCreate) return onCreate(validated);
  const interest = await execute({ path: '/news/interests' + (state.existing ? '/' + state.existing.id : ''),
    method: state.existing ? 'PUT' : 'POST',
    body: { ...validated, ...(state.existing ? { expectedRevision: state.existing.revision } : {}) } });
  return { interest, created: !state.existing };
}
/** Admission is synchronous, including clicks before React renders pending. */
export function createInterestEditorSubmission() {
  let pending = false;
  return {
    get pending() { return pending; },
    async submit(operation: () => Promise<void>): Promise<boolean> {
      if (pending) return false;
      pending = true;
      try { await operation(); return true; } finally { pending = false; }
    },
    cancel(onClose: () => void): boolean {
      if (pending) return false;
      onClose(); return true;
    },
  };
}

export function InterestEditor(props: InterestEditorProps) {
  return <InterestEditorForm key={interestEditorIdentity(props, props.editorID)} {...props} />;
}
function InterestEditorForm(props: InterestEditorProps) {
  // Pin both the draft and edit revision to this identity. A changed revision
  // must cause a normal server conflict, not silently rebase unsaved edits.
  const [initial] = useState(() => createInterestEditorState(props));
  const [draft, setDraft] = useState(initial.draft);
  const [required, setRequired] = useState(draft.requiredTerms.join('\n'));
  const [excluded, setExcluded] = useState(draft.excludedTerms.join('\n'));
  const [error, setError] = useState<string | Error>('');
  const [submission] = useState(createInterestEditorSubmission);
  const [saving, setSaving] = useState(false);
  const command = useCommand<NewsInterest>(['news']);
  const editing = !!initial.existing;
  const headingID = useId(), Heading = props.headingLevel === 3 ? 'h3' : 'h2';
  function change<K extends keyof InterestDraft>(key: K, value: InterestDraft[K]) { setDraft(d => ({ ...d, [key]: value })); }
  async function save(e: FormEvent) {
    e.preventDefault();
    await submission.submit(async () => {
      setError('');
      const validated = validateInterestEditorDraft(draft, required, excluded);
      if (!validated.success) { setError(validated.error.issues.map(i => i.message).join(' ')); return; }
      setSaving(true);
      try {
        const result = await saveInterestEditor(initial, validated.data, command.mutateAsync, props.onCreate);
        props.onSaved?.(result);
        props.onClose();
      } catch (failure) {
        setError(failure instanceof Error ? failure : 'Could not save this interest. Your draft is kept; try again.');
      } finally { setSaving(false); }
    });
  }
  return <form className="panel editor interest-editor" aria-labelledby={headingID} onSubmit={save}>
    <Heading id={headingID}>{editing ? 'Refine your interest' : 'What would you like to follow?'}</Heading>
    <label>Name<input required maxLength={100} value={draft.name} onChange={e => change('name', e.target.value)} placeholder="Developer jobs in Japan" /></label>
    <label>What should we look for?<textarea required minLength={3} maxLength={600} rows={3} value={draft.query} onChange={e => change('query', e.target.value)} placeholder="Software developer jobs in Japan with English-speaking teams and visa sponsorship" /></label>
    <div className="form-grid">
      <label>Looking for<select value={draft.intent} onChange={e => change('intent', e.target.value as InterestDraft['intent'])}><option value="news">News & announcements</option><option value="opportunities">Jobs & opportunities</option></select></label>
      <label>Published within<select value={draft.days} onChange={e => change('days', Number(e.target.value) as InterestDraft['days'])}><option value={1}>24 hours</option><option value={7}>7 days</option><option value={30}>30 days</option></select></label>
      <label>Result language<select value={draft.language} onChange={e => change('language', e.target.value as InterestDraft['language'])}><option value="en">English</option><option value="ja">Japanese</option></select></label>
      <label>Search region<select value={draft.region} onChange={e => change('region', e.target.value as InterestDraft['region'])}><option value="US">United States</option><option value="JP">Japan</option><option value="GB">United Kingdom</option><option value="PH">Philippines</option></select></label>
    </div>
    <details className="interest-filters">
      <summary>Fine-tune matching</summary>
      <p className="muted">Each required line must match the title or summary. Use | for alternatives, such as Japan|Tokyo|Osaka. Leave blank to let the search query decide.</p>
      <div className="form-grid"><label>Required keyword groups<textarea rows={4} value={required} onChange={e => setRequired(e.target.value)} placeholder={'Japan|Tokyo|Osaka\nsoftware|developer|engineer\njob|hiring|career'} /></label>
        <label>Exclude phrases<textarea rows={4} value={excluded} onChange={e => setExcluded(e.target.value)} placeholder={'stock price\ncelebrity'} /></label></div>
      <p className="footnote">Up to 8 required groups and 12 exclusions. Update these when changing language. Results without a known publication date are clearly labeled.</p>
    </details>
    <ErrorMessage error={error} />
    <div className="actions"><button type="submit" className="button primary" disabled={saving}><Plus size={15} />{saving ? 'Saving…' : editing ? 'Save interest' : 'Add interest'}</button><button type="button" className="button secondary" disabled={saving} onClick={() => submission.cancel(props.onClose)}>Cancel</button></div>
  </form>;
}
