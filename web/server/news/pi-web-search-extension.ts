import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

// This explicit extension is the only extension enabled for discovery. It adds
// a hosted provider tool, never shell, filesystem or user-installed tools.
type Data = Record<string, unknown>;
const object = (value: unknown): Data => value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Data : {};
interface Context { cwd: string; model?: { api: string } }
interface SearchExtensionAPI {
  on(event: 'before_provider_request', handler: (event: { payload: unknown }, context: Context) => unknown): void;
  on(event: 'provider_stream_event', handler: (event: { data: unknown }, context: Context) => void): void;
}
export default function webSearchExtension(pi: SearchExtensionAPI) {
  const urls = new Set<string>(), searches = new Set<string>();
  pi.on('before_provider_request', (event, context) => {
    if (!['openai-codex-responses', 'openai-responses'].includes(context.model?.api ?? '')) {
      throw new Error('This PI provider does not support hosted web search.');
    }
    const payload = object(event.payload);
    return { ...payload, tools: [{ type: 'web_search', external_web_access: true }], tool_choice: 'required',
      include: [...new Set([...(Array.isArray(payload.include) ? payload.include : []), 'web_search_call.action.sources'])] };
  });
  pi.on('provider_stream_event', (event, context) => {
    const data = object(event.data), response = object(data.response);
    const items = data.type === 'response.output_item.done' ? [data.item] :
      ['response.completed', 'response.done'].includes(String(data.type)) && Array.isArray(response.output) ? response.output : [];
    for (const value of items) {
      const item = object(value), action = object(item.action);
      if (item.type !== 'web_search_call' || item.status !== 'completed') continue;
      if (action.type === 'search') searches.add(String(item.id ?? JSON.stringify(action)));
      const sources = Array.isArray(action.sources) ? action.sources : [];
      for (const source of [...sources.map(source => object(source).url), action.url]) {
        if (typeof source !== 'string' || source.length > 4096 || urls.size >= 200) continue;
        try {
          const url = new URL(source);
          if (['https:', 'http:'].includes(url.protocol) && !url.username && !url.password) urls.add(url.href);
        } catch { /* Invalid provider evidence is not accepted. */ }
      }
    }
    if (items.length) writeFileSync(join(context.cwd, 'web-search-evidence.json'), JSON.stringify({
      searches: searches.size, urls: [...urls],
    }), { mode: 0o600 });
  });
}
