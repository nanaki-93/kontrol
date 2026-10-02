import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { mkdtemp, mkdir, writeFile, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runPI } from '../server/news/pi';

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
