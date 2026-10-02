import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { Sparkles } from 'lucide-react';
import type { NewsResponse } from '../../../shared/news';
import { Badge, ErrorMessage } from '../../components/ui';

export function AIConnection({ ai, searching }: { ai: NewsResponse['ai']; searching: boolean }) {
  const client = useQueryClient();
  const [pending, setPending] = useState(false), [error, setError] = useState<unknown>(null);
  async function refresh() {
    setPending(true); setError(null);
    try { await client.invalidateQueries({ queryKey: ['news'] }, { throwOnError: true }); }
    catch (failure) { setError(failure); } finally { setPending(false); }
  }
  return <div className="ai-connection">
    <div className="row-spread"><h3><Sparkles size={16} /> AI search with PI</h3><Badge tone={ai.configured ? 'success' : ''}>{ai.configured ? 'PI available' : 'Setup needed'}</Badge></div>
    <p className="muted">PI ranks live news and web search results, summarizes the sources, and explains why each result fits your interest.</p>
    <p className="footnote">{ai.model} · {ai.message}</p>
    {!ai.configured && <p className="footnote">Install PI 1.0 or later on this Mac, sign in with <code>/login</code> and save a default model with <code>/model</code> in PI. Then refresh this connection.</p>}
    <button className="button secondary" disabled={pending || searching} onClick={() => void refresh()}>{pending ? 'Checking…' : 'Refresh PI connection'}</button>
    <p className="footnote">Uses your existing PI account and its provider’s usage limits or billing. Only selected interests, filters and retrieved search snippets are sent. Credentials stay managed by PI. Standard search needs no AI account.</p>
    <ErrorMessage error={error} />
  </div>;
}
