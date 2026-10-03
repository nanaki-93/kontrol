import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { mkdtemp, mkdir, writeFile, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runPI, runPIWebSearch } from '../server/news/pi';

// Explicit opt-in selects a local PI installation. All credentials and HTTP
// responses are fixtures; this never connects to a paid model or a user's PI data.
test('installed PI CLI isolates inference and handles provider failures without retries', {
  skip: !process.env.KONTROL_TEST_PI_COMMAND, timeout: 20_000,
}, async () => {
  const directory = await mkdtemp(join(tmpdir(), 'kontrol-pi-cli-test-'));
  let calls = 0;
  let fail = false;
  const payloads: Record<string, unknown>[] = [];
  const server = createServer((req, res) => {
    let body = '';
    req.setEncoding('utf8'); req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      calls++;
      payloads.push(JSON.parse(body));
      if (fail) { res.writeHead(503, { 'Content-Type': 'application/json' }); res.end('{"error":{"message":"private-fixture-provider-error"}}'); return; }
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      const chunk = { id: 'kontrol-fixture', object: 'chat.completion.chunk', created: 1, model: 'fixture-model' };
      res.write('data: ' + JSON.stringify({ ...chunk, choices: [{ index: 0, delta: { role: 'assistant', content: '{"articles":[]}' }, finish_reason: null }] }) + '\n\n');
      res.write('data: ' + JSON.stringify({ ...chunk, choices: [{ index: 0, delta: {}, finish_reason: 'stop' }], usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } }) + '\n\n');
      res.end('data: [DONE]\n\n');
    });
  });
  try {
    await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
    const port = (server.address() as AddressInfo).port;
    const settings = JSON.stringify({ defaultProvider: 'kontrol-fixture', defaultModel: 'fixture-model',
      retry: { enabled: true, maxRetries: 3 }, enableInstallTelemetry: false, enableAnalytics: false });
    await writeFile(join(directory, 'settings.json'), settings);
    await writeFile(join(directory, 'auth.json'), '{}');
    await writeFile(join(directory, 'models.json'), JSON.stringify({ providers: { 'kontrol-fixture': {
      baseUrl: 'http://127.0.0.1:' + port + '/v1', api: 'openai-completions', apiKey: 'fixture-key-only',
      models: [{ id: 'fixture-model', contextWindow: 32768, maxTokens: 1000 }],
    } } }));
    await writeFile(join(directory, 'AGENTS.md'), 'PRIVATE-CONTEXT-MUST-NOT-LOAD');
    await mkdir(join(directory, 'extensions'));
    await writeFile(join(directory, 'extensions', 'must-not-load.ts'), 'throw new Error("PRIVATE-EXTENSION-MUST-NOT-LOAD");');
    const result = await runPI('Return JSON for this fixture interest.', {
      command: process.env.KONTROL_TEST_PI_COMMAND, agentDir: directory,
    }, AbortSignal.timeout(15_000));
    assert.deepEqual(JSON.parse(result), { articles: [] });
    assert.equal(calls, 1);
    assert.doesNotMatch(JSON.stringify(payloads), /PRIVATE-CONTEXT|PRIVATE-EXTENSION/);
    assert.equal(payloads[0].model, 'fixture-model');
    assert.ok(!payloads[0].tools || (payloads[0].tools as unknown[]).length === 0);
    assert.match(JSON.stringify(payloads[0].messages), /fixture interest/);
    fail = true;
    await assert.rejects(runPI('Return JSON for this failing fixture.', {
      command: process.env.KONTROL_TEST_PI_COMMAND, agentDir: directory,
    }, AbortSignal.timeout(15_000)), error => error instanceof Error && /PI/.test(error.message) && !error.message.includes('private-fixture-provider-error'));
    assert.equal(calls, 2, 'Exactly one provider request per invocation, even with global PI retries enabled');
    assert.equal(await readFile(join(directory, 'settings.json'), 'utf8'), settings);
    assert.equal((await readdir(directory)).includes('sessions'), false);
  } finally {
    server.closeAllConnections();
    await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(directory, { recursive: true, force: true });
  }
});

test('installed PI loads only the hosted-search extension and requires completed provider evidence', {
  skip: !process.env.KONTROL_TEST_PI_COMMAND, timeout: 25_000,
}, async () => {
  const directory = await mkdtemp(join(tmpdir(), 'kontrol-pi-search-cli-test-'));
  const payloads: Record<string, unknown>[] = [];
  let includeEvidence = true;
  const url = 'https://example.com/jobs/backend';
  const answer = JSON.stringify({ links: [{ url, title: 'Backend engineer' }] });
  const server = createServer((req, res) => {
    let body = '';
    req.setEncoding('utf8'); req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      payloads.push(JSON.parse(body));
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      const send = (event: object) => res.write('data: ' + JSON.stringify(event) + '\n\n');
      const call = { id: 'search-fixture', type: 'web_search_call', status: 'completed',
        action: { type: 'search', queries: ['fixture jobs'], sources: [{ type: 'url', url }] } };
      const message = { id: 'message-fixture', type: 'message', role: 'assistant', status: 'completed',
        content: [{ type: 'output_text', text: answer, annotations: [] }] };
      send({ type: 'response.created', response: { id: 'response-fixture', status: 'in_progress' } });
      if (includeEvidence) send({ type: 'response.output_item.done', output_index: 0, item: call });
      send({ type: 'response.output_item.added', output_index: 1, item: { ...message, content: [], status: 'in_progress' } });
      send({ type: 'response.content_part.added', output_index: 1, content_index: 0, part: { type: 'output_text', text: '', annotations: [] } });
      send({ type: 'response.output_text.delta', output_index: 1, content_index: 0, delta: answer });
      send({ type: 'response.output_item.done', output_index: 1, item: message });
      send({ type: 'response.completed', response: { id: 'response-fixture', status: 'completed',
        output: includeEvidence ? [call, message] : [message],
        usage: { input_tokens: 10, output_tokens: 5, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } },
      } });
      res.end();
    });
  });
  try {
    await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
    const port = (server.address() as AddressInfo).port;
    const settings = JSON.stringify({ defaultProvider: 'openai', defaultModel: 'fixture-model', enableInstallTelemetry: false, enableAnalytics: false });
    await writeFile(join(directory, 'settings.json'), settings);
    await writeFile(join(directory, 'auth.json'), '{}');
    await writeFile(join(directory, 'models.json'), JSON.stringify({ providers: { openai: {
      baseUrl: 'http://127.0.0.1:' + port + '/v1', api: 'openai-responses', apiKey: 'fixture-key-only',
      models: [{ id: 'fixture-model', contextWindow: 32768, maxTokens: 1000 }],
    } } }));
    await writeFile(join(directory, 'AGENTS.md'), 'PRIVATE-CONTEXT-MUST-NOT-LOAD');
    await mkdir(join(directory, 'extensions'));
    await writeFile(join(directory, 'extensions', 'must-not-load.ts'), 'throw new Error("PRIVATE-EXTENSION-MUST-NOT-LOAD");');
    const options = { command: process.env.KONTROL_TEST_PI_COMMAND, agentDir: directory, timeoutMs: 10_000 };
    const result = await runPIWebSearch('Search for public fixture jobs.', options);
    assert.deepEqual(JSON.parse(result.text), JSON.parse(answer));
    assert.deepEqual(result.urls, [url]);
    assert.equal(payloads.length, 1);
    assert.deepEqual(payloads[0].tools, [{ type: 'web_search', external_web_access: true }]);
    assert.equal(payloads[0].tool_choice, 'required');
    assert.ok((payloads[0].include as string[]).includes('web_search_call.action.sources'));
    assert.doesNotMatch(JSON.stringify(payloads), /PRIVATE-CONTEXT|PRIVATE-EXTENSION/);
    includeEvidence = false;
    await assert.rejects(runPIWebSearch('Search for public fixture jobs.', options), /completed web-search evidence/);
    assert.equal(payloads.length, 2);
    assert.equal(await readFile(join(directory, 'settings.json'), 'utf8'), settings);
    assert.equal((await readdir(directory)).includes('sessions'), false);
  } finally {
    server.closeAllConnections();
    await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(directory, { recursive: true, force: true });
  }
});
