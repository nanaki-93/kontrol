import { useState, type ChangeEvent } from 'react';
import { FileText, Upload, Trash2, Sparkles } from 'lucide-react';
import { MAX_CV_BYTES, type JobsResponse } from '../../../shared/jobs';
import { Badge, Confirm, ErrorMessage, formatDate } from '../../components/ui';
import { useJobCommand } from './api';
import { JobSetupPanel } from './setup-panel';

function fileBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(',')[1]);
    reader.onerror = () => reject(new Error('This file could not be read. Try selecting it again.'));
    reader.readAsDataURL(file);
  });
}
export function CVPanel({ state, busy }: { state: JobsResponse; busy: boolean }) {
  const command = useJobCommand();
  const [reading, setReading] = useState(false), [error, setError] = useState<unknown>(null), [remove, setRemove] = useState(false);
  const pending = busy || reading || command.isPending;
  async function upload(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0]; event.target.value = '';
    if (!file) return;
    setReading(true); setError(null);
    try {
      if (file.size > MAX_CV_BYTES) throw new Error('Choose a PDF, DOCX or TXT CV up to 5 MB.');
      if (!/\.(pdf|docx|txt)$/i.test(file.name)) throw new Error('Choose a PDF, DOCX or UTF-8 TXT file.');
      const base64 = await fileBase64(file);
      await command.mutateAsync({ path: '/cv', body: { name: file.name, base64, expectedRevision: state.revision } });
    } catch (failure) { setError(failure); }
    finally { setReading(false); }
  }
  return <JobSetupPanel name="cv" eyebrow="01 / YOUR EXPERIENCE" title="Your CV" icon={<FileText size={22} />}
    defaultExpanded={!state.profileConfirmed} summary={state.cv ? `${state.cv.name} · ${state.profileConfirmed ? 'Profile confirmed' : state.profile ? 'Profile ready to review' : 'Ready to analyze'}` : 'Upload a PDF, DOCX or TXT CV to get started.'}
    feedback={<ErrorMessage error={error ?? command.error} />}>
    <p className="muted">Bring your experience, skills and career history. AI will turn them into a profile you can review.</p>
    <div className={'job-upload' + (state.cv ? ' has-cv' : '')}>
      {state.cv ? <><FileText size={28} /><strong className="break-word">{state.cv.name}</strong><span className="row-meta">{Math.ceil(state.cv.bytes / 1024)} KB · added {formatDate(state.cv.uploadedAt)}</span><Badge tone="success">CV ready</Badge></> : <><Upload size={27} /><strong>A little context for your next move.</strong><span className="muted">PDF, DOCX or TXT · up to 5 MB · PDF up to 25 pages</span></>}
      <label className={'button secondary file-button' + (pending ? ' disabled' : '')}><Upload size={15} />{reading ? 'Reading CV…' : state.cv ? 'Replace CV' : 'Upload CV'}<input aria-label={state.cv ? 'Replace CV' : 'Upload CV'} type="file" accept=".pdf,.docx,.txt,application/pdf,application/vnd.openxmlformats-officedocument.wordprocessingml.document,text/plain" disabled={pending} onChange={event => void upload(event)} /></label>
    </div>
    {state.cv && <details className="job-cv-preview"><summary>Review extracted text</summary><pre>{state.cv.text}</pre></details>}
    <p className="footnote">Upload stays on this Mac. Analyze sends the extracted CV text to your configured PI AI provider. Check the text above first. Scanned PDFs need OCR before upload. Replacing a CV clears its profile and matches.</p>
    <div className="actions"><button className="button primary" disabled={pending || !state.cv || !state.ai.configured} onClick={() => command.mutate({ path: '/analyze', body: { expectedRevision: state.revision } })}><Sparkles size={16} />{state.activity === 'analyzing' ? 'Analyzing CV…' : state.profile ? 'Analyze CV again' : 'Analyze CV'}</button>
      {state.cv && <button className="text-link" disabled={pending} onClick={() => setRemove(true)}><Trash2 size={14} />Remove CV</button>}</div>
    {remove && <Confirm title="Remove your CV and profile?" description="This removes the saved CV text, professional profile and job matches from this workspace. Your original file and any backups remain. Search preferences are kept." label="Remove CV" pending={command.isPending} onCancel={() => setRemove(false)} onConfirm={() => command.mutate({ path: '/cv', method: 'DELETE', body: { expectedRevision: state.revision } }, { onSuccess: () => setRemove(false) })} />}
  </JobSetupPanel>;
}
