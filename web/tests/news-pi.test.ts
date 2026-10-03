import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parsePIOutput, piStatus, runPI, runPIWebSearch } from '../server/news/pi';
import webSearchExtension from '../server/news/pi-web-search-extension';

function events(text = '{"articles":[]}', stopReason = 'stop') {
  return [
    { type: 'session', version: 3 },
    { type: 'message_end', message: { role: 'user', content: 'Literal user input' } },
    { type: 'message_update', assistantMessageEvent: { type: 'text_delta', delta: 'Ignored partial' } },
    { type: 'message_end', message: { role: 'assistant', stopReason, content: [{ type: 'text', text }] } },
    { type: 'agent_end', messages: [] }, { type: 'agent_settled' },
  ].map(event => JSON.stringify(event)).join('\n') + '\n';
}
async function fixture(run: (directory: string, command: string) => Promise<void>, script: string) {
  const directory = await mkdtemp(join(tmpdir(), 'kontrol-pi-fixture-'));
  const command = join(directory, 'pi-fixture.cjs');
  try {
    await writeFile(command, '#!' + process.execPath + '\n' + script, { mode: 0o700 });
    await writeFile(join(directory, 'settings.json'), JSON.stringify({ defaultProvider: 'fixture', defaultModel: 'fixture-model' }));
    await run(directory, command);
  } finally { await rm(directory, { recursive: true, force: true }); }
}
test('PI output uses final messages and rejects incomplete, failed, tool and malformed responses', () => {
  const text = '{"articles":[],"note":"Unicode\u2028separator"}';
  assert.equal(parsePIOutput(events(text)), text);
  for (const output of ['not JSON', events().replace('{"type":"agent_settled"}\n', ''),
    ...['error', 'aborted', 'length', 'toolUse'].map(reason => events('private-error', reason)), events('')]) {
    assert.throws(() => parsePIOutput(output), error => error instanceof Error && /PI did not return/.test(error.message) && !error.message.includes('private-error'));
  }
});
test('PI status reads only nonsecret model settings, supports overrides and reports missing configuration', async () => {
  await fixture(async (directory, command) => {
    const before = await readFile(join(directory, 'settings.json'), 'utf8');
    await writeFile(join(directory, 'auth.json'), 'Do not read or parse this credential fixture');
    const status = await piStatus({ command, agentDir: directory });
    assert.equal(status.configured, true); assert.equal(status.provider, 'pi');
    assert.equal(status.model, 'fixture/fixture-model');
    assert.equal((await piStatus({ command, agentDir: directory, provider: 'override', model: 'other' })).model, 'override/other');
    assert.equal((await piStatus({ command, agentDir: directory, model: 'override/other' })).model, 'override/other');
    assert.equal(await readFile(join(directory, 'settings.json'), 'utf8'), before);
    assert.equal((await piStatus({ command: join(directory, 'missing'), agentDir: directory })).configured, false);
    await writeFile(join(directory, 'settings.json'), 'invalid private configuration');
    const invalid = await piStatus({ command, agentDir: directory });
    assert.equal(invalid.configured, false); assert.doesNotMatch(JSON.stringify(invalid), /invalid private/);
  }, 'process.exit(99)');
});
test('PI process uses isolated settings, literal stdin, no shell/tools/context/session and cleans up', async () => {
  await fixture(async (directory, command) => {
    const prompt = '@private-file --model injected $(touch unsafe) `echo unsafe`\n{"articles":[]}';
    const before = await readFile(join(directory, 'settings.json'), 'utf8');
    const text = await runPI(prompt, { command, agentDir: directory });
    const report = JSON.parse(text);
    assert.equal(report.input, prompt);
    assert.equal(report.agentDir, directory);
    for (const flag of ['--print', '--no-tools', '--no-extensions', '--no-context-files', '--no-session', '--no-skills', '--no-prompt-templates', '--no-themes', '--offline', '--approve']) assert.ok(report.args.includes(flag));
    assert.equal(report.args.includes(prompt), false);
    assert.equal(report.args[report.args.indexOf('--mode') + 1], 'json');
    assert.equal(report.args[report.args.indexOf('--model') + 1], 'fixture-model');
    assert.equal(report.args[report.args.indexOf('--provider') + 1], 'fixture');
    assert.equal(report.settings.retry.enabled, false);
    assert.equal(report.settings.retry.provider.maxRetries, 0);
    assert.equal(report.settings.compaction.enabled, false);
    assert.notEqual(report.cwd, process.cwd());
    await assert.rejects(access(report.cwd), { code: 'ENOENT' });
    assert.equal(await readFile(join(directory, 'settings.json'), 'utf8'), before);
  }, `const fs = require('node:fs'); let input = ''; process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => {
  const report = { input, cwd: process.cwd(), args: process.argv.slice(2), agentDir: process.env.PI_CODING_AGENT_DIR,
    settings: JSON.parse(fs.readFileSync('.pi/settings.json', 'utf8')) };
  console.log(JSON.stringify({ type: 'message_end', message: { role: 'assistant', stopReason: 'stop', content: [{ type: 'text', text: JSON.stringify(report) }] } }));
  console.log(JSON.stringify({ type: 'agent_settled' }));
});`);
});
test('PI process failures and excessive output are sanitized without retrying', async () => {
  for (const script of ["process.stderr.write('fixture-secret-key'); process.exit(1);", "process.stdout.write('x'.repeat(2100000));"]) {
    await fixture(async (directory, command) => {
      await assert.rejects(runPI('fixture', { command, agentDir: directory }), error =>
        error instanceof Error && !error.message.includes('fixture-secret-key') && /PI/.test(error.message));
    }, script);
  }
});
test('PI cancellation kills the child and removes temporary files', async () => {
  await fixture(async (directory, command) => {
    const controller = new AbortController();
    const pending = runPI('fixture', { command, agentDir: directory }, controller.signal);
    const marker = join(directory, 'started.json');
    // A bounded wait for the fixture process, not a live application journey.
    let report: { cwd: string; pid: number } | undefined;
    for (let attempt = 0; attempt < 100 && !report; attempt++) {
      try { report = JSON.parse(await readFile(marker, 'utf8')); }
      catch { await new Promise(resolve => setTimeout(resolve, 10)); }
    }
    controller.abort();
    await assert.rejects(pending, /timed out|interrupted/);
    assert.ok(report, 'Fixture must have started');
    await assert.rejects(access(report.cwd), { code: 'ENOENT' });
    assert.throws(() => process.kill(report.pid, 0), { code: 'ESRCH' });
  }, `require('node:fs').writeFileSync(require('node:path').join(process.env.PI_CODING_AGENT_DIR, 'started.json'), JSON.stringify({ cwd: process.cwd(), pid: process.pid })); setInterval(() => {}, 1000);`);
});
test('PI honors an explicit deadline even when its caller has no deadline, then reaps and cleans up', async () => {
  await fixture(async (directory, command) => {
    const started = Date.now();
    await assert.rejects(runPI('fixture', { command, agentDir: directory, timeoutMs: 1000 }, new AbortController().signal), /took too long/);
    assert.ok(Date.now() - started < 5000);
    const report = JSON.parse(await readFile(join(directory, 'started.json'), 'utf8'));
    await assert.rejects(access(report.cwd), { code: 'ENOENT' });
    assert.throws(() => process.kill(report.pid, 0), { code: 'ESRCH' });
  }, `require('node:fs').writeFileSync(require('node:path').join(process.env.PI_CODING_AGENT_DIR, 'started.json'), JSON.stringify({ cwd: process.cwd(), pid: process.pid })); setInterval(() => {}, 1000);`);
});
test('native search enables only the hosted tool and records provider evidence rather than assistant URLs', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'kontrol-search-extension-'));
  // The same two callbacks are exercised by the installed-CLI fixture below.
  const handlers: Record<string, (event: any, context: any) => unknown> = {};
  webSearchExtension({ on(event: string, handler: (event: any, context: any) => unknown) { handlers[event] = handler; } });
  const context = { cwd: directory, model: { api: 'openai-codex-responses' } };
  try {
    const payload = handlers.before_provider_request({ payload: { tools: [{ type: 'function', name: 'bash' }], include: ['reasoning.encrypted_content'] } }, context) as Record<string, unknown>;
    assert.deepEqual(payload.tools, [{ type: 'web_search', external_web_access: true }]);
    assert.equal(payload.tool_choice, 'required');
    assert.deepEqual(payload.include, ['reasoning.encrypted_content', 'web_search_call.action.sources']);
    assert.throws(() => handlers.before_provider_request({ payload: {} }, { ...context, model: { api: 'other' } }), /does not support/);
    const call = { type: 'web_search_call', id: 'search-1', status: 'completed', action: { type: 'search', sources: [
      { type: 'url', url: 'https://example.com/jobs/backend' }, { type: 'url', url: 'file:///private' },
    ] } };
    handlers.provider_stream_event({ data: { type: 'response.output_item.done', item: call } }, context);
    handlers.provider_stream_event({ data: { type: 'response.completed', response: { output: [call,
      { type: 'message', content: [{ type: 'output_text', text: 'https://invented.example/jobs/fake' }] },
    ] } } }, context);
    assert.deepEqual(JSON.parse(await readFile(join(directory, 'web-search-evidence.json'), 'utf8')), {
      searches: 1, urls: ['https://example.com/jobs/backend'],
    });
  } finally { await rm(directory, { recursive: true, force: true }); }
});
test('PI native search loads one explicit extension and retains process isolation and cleanup', async () => {
  await fixture(async (directory, command) => {
    const result = await runPIWebSearch('Search only public jobs.', { command, agentDir: directory, provider: 'openai-codex' });
    const report = JSON.parse(result.text);
    assert.deepEqual(result.urls, ['https://example.com/jobs/backend']);
    for (const flag of ['--no-tools', '--no-extensions', '--no-context-files', '--no-session']) assert.ok(report.args.includes(flag));
    assert.equal(report.args.filter((arg: string) => arg === '--extension').length, 1);
    assert.match(report.args[report.args.indexOf('--extension') + 1], /pi-web-search-extension\.ts$/);
    await assert.rejects(access(report.cwd), { code: 'ENOENT' });
  }, `const fs = require('node:fs'); process.stdin.resume(); process.stdin.on('end', () => {
    fs.writeFileSync('web-search-evidence.json', JSON.stringify({ searches: 1, urls: ['https://example.com/jobs/backend'] }));
    const report = { cwd: process.cwd(), args: process.argv.slice(2) };
    console.log(JSON.stringify({ type: 'message_end', message: { role: 'assistant', stopReason: 'stop', content: [{ type: 'text', text: JSON.stringify(report) }] } }));
    console.log(JSON.stringify({ type: 'agent_settled' }));
  });`);
});
test('native search rejects answers without completed provider evidence and unsupported providers', async () => {
  for (const evidence of [null, { searches: 0, urls: ['https://example.com/jobs/remembered'] }]) {
    await fixture(async (directory, command) => {
      await assert.rejects(runPIWebSearch('Search public jobs.', { command, agentDir: directory, provider: 'openai-codex' }), /completed web-search evidence/);
      await assert.rejects(runPIWebSearch('Search public jobs.', { command, agentDir: directory }), /needs an OpenAI Responses or Codex model/);
    }, `process.stdin.resume(); process.stdin.on('end', () => {
      const evidence = ${JSON.stringify(evidence)};
      if (evidence) require('node:fs').writeFileSync('web-search-evidence.json', JSON.stringify(evidence));
      process.stdout.write(${JSON.stringify(events('{"links":[{"url":"https://example.com/jobs/remembered","title":"Backend engineer"}]}'))});
    });`);
  }
});
