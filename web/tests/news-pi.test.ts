import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parsePIOutput, piStatus, runPI } from '../server/news/pi';

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
