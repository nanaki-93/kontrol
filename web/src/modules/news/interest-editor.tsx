import { useState, type FormEvent } from 'react';
import { Plus } from 'lucide-react';
import { interestDraftSchema, type InterestDraft, type NewsInterest } from '../../../shared/news';
import { useCommand } from '../../lib/api';
import { ErrorMessage } from '../../components/ui';

const blank: InterestDraft = { name: '', query: '', language: 'en', region: 'US', days: 7,
  intent: 'news', requiredTerms: [], excludedTerms: [], enabled: true };
const lines = (value: string) => value.split('\n').map(t => t.trim()).filter(Boolean);

export function InterestEditor({ interest, onClose }: { interest?: NewsInterest; onClose: () => void }) {
  const [draft, setDraft] = useState<InterestDraft>(interest ?? blank);
  const [required, setRequired] = useState(draft.requiredTerms.join('\n'));
  const [excluded, setExcluded] = useState(draft.excludedTerms.join('\n'));
  const [error, setError] = useState('');
  const command = useCommand(['news']);
  function change<K extends keyof InterestDraft>(key: K, value: InterestDraft[K]) { setDraft(d => ({ ...d, [key]: value })); }
  async function save(e: FormEvent) {
    e.preventDefault(); setError('');
    const result = interestDraftSchema.safeParse({ ...draft, requiredTerms: lines(required), excludedTerms: lines(excluded) });
    if (!result.success) { setError(result.error.issues.map(i => i.message).join(' ')); return; }
    try {
      await command.mutateAsync({ path: '/news/interests' + (interest ? '/' + interest.id : ''), method: interest ? 'PUT' : 'POST',
        body: { ...result.data, ...(interest ? { expectedRevision: interest.revision } : {}) } });
      onClose();
    } catch { /* Keep the draft for correction or conflict review. */ }
  }
  return <form className="panel editor interest-editor" onSubmit={save}>
    <h2>{interest ? 'Refine your interest' : 'What would you like to follow?'}</h2>
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
    <ErrorMessage error={error || command.error} />
    <div className="actions"><button className="button primary" disabled={command.isPending}><Plus size={15} />{command.isPending ? 'Saving…' : interest ? 'Save interest' : 'Add interest'}</button><button type="button" className="button secondary" disabled={command.isPending} onClick={onClose}>Cancel</button></div>
  </form>;
}
