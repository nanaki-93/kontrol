import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { sessionSchema, nativeExportSchema, defaultLayout, layoutSchema, type Session, type Feed } from '../shared/schema';
import { overlap, isTaskForDay, fromDayInput } from '../shared/dates';
import { activeSeconds, transition } from '../server/modules/focus';
import { initialLearning, fillSlots, practicedConcepts } from '../server/modules/learning';
import { canonicalURL, isPublicIP, parseFeed, mergeArticles } from '../server/modules/news';

const start = Date.parse('2026-10-02T01:00:00.000Z');
function session(): Session {
  return { id: randomUUID(), state: 'running', plannedSeconds: 1500, accumulatedActiveSeconds: 0,
    activeSegmentStartedAt: new Date(start).toISOString(), deadline: new Date(start + 1500_000).toISOString(),
    pausedAt: null, startedAt: new Date(start).toISOString(), endedAt: null, checkpointAt: new Date(start).toISOString(),
    recoveryRequired: false, linkedTaskID: null, linkedLessonID: null, linkedTitleSnapshot: null };
}
test('Focus excludes paused time and completes exactly once after resume', () => {
  const paused = sessionSchema.parse(transition(session(), 'pause', start + 300_000));
  assert.equal(activeSeconds(paused, start + 900_000), 300);
  const resumed = sessionSchema.parse(transition(paused, 'resume', start + 900_000));
  assert.equal(activeSeconds(resumed, start + 1000_000), 400);
  const completed = sessionSchema.parse(transition(resumed, 'reconcile', start + 3000_000));
  assert.equal(completed.accumulatedActiveSeconds, 1500);
  assert.equal(completed.state, 'completed');
  assert.deepEqual(transition(completed, 'end', start + 4000_000), completed);
});
test('Focus recovers a backward clock and caps time after process downtime', () => {
  const recovered = sessionSchema.parse(transition(session(), 'reconcile', start - 5000));
  assert.equal(recovered.state, 'paused');
  assert.equal(recovered.recoveryRequired, true);
  assert.equal(activeSeconds(recovered, start + 86_400_000), 0);
  const complete = transition(session(), 'reconcile', start + 86_400_000);
  assert.equal(complete.accumulatedActiveSeconds, 1500);
  assert.equal(complete.endedAt, session().deadline);
});
test('half-open schedule intervals allow touching boundaries', () => {
  const a = { startAt: '2026-10-02T08:00:00.000Z', endAt: '2026-10-02T09:00:00.000Z' };
  assert.equal(overlap(a, { startAt: a.endAt, endAt: '2026-10-02T10:00:00.000Z' }), false);
  assert.equal(overlap(a, { startAt: '2026-10-02T08:30:00.000Z', endAt: '2026-10-02T09:30:00.000Z' }), true);
});
test('planned days stay calendar dates, separate from due instants', () => {
  const task = { id: randomUUID(), title: 'Plan', notes: null, dueAt: null, plannedDay: fromDayInput('2026-10-03'),
    createdAt: new Date(start).toISOString(), completedAt: null };
  assert.equal(isTaskForDay(task, '2026-10-02'), false);
  assert.equal(isTaskForDay(task, '2026-10-03'), true);
});
test('catalog loads all forty authored lessons with four stable choices per topic', () => {
  const state = initialLearning();
  assert.equal(state.definitions.length, 40);
  assert.equal(state.topics.length, 5);
  for (const topic of state.topics) assert.equal(state.slots.filter(s => s.topicID === topic.id).length, 4);
  const before = structuredClone(state.slots);
  fillSlots(state, new Date().toISOString());
  assert.deepEqual(state.slots, before);
});
test('lesson replacement preserves other slots, suppresses terminal content and derives coverage from saved evidence', () => {
  const state = initialLearning(), first = state.slots[0];
  const definition = state.definitions.find(d => d.id === first.lessonID)!;
  const other = state.slots.filter(s => s.key !== first.key);
  const at = new Date(start).toISOString();
  state.progress.push({ lessonID: definition.id, status: 'completed', firstShownAt: at, startedAt: at, completedAt: at, dismissedAt: null, lastOpenedAt: at });
  state.attempts.push({ id: randomUUID(), lessonID: definition.id, contentVersion: definition.contentVersion,
    answerDraft: 'My answer', revision: 1, completedAt: at, solutionRevealedAt: at, selfCheckAcknowledgedAt: at,
    pinnedContent: { envelopeVersion: 1, definition: structuredClone(definition) }, completedContentSnapshot: null });
  state.definitions.push({ ...definition, id: 'renamed-clone', title: 'Different title' });
  fillSlots(state, at);
  assert.deepEqual(state.slots.filter(s => s.key !== first.key), other);
  assert.equal(state.slots.some(s => [definition.id, 'renamed-clone'].includes(s.lessonID)), false);
  definition.conceptIDs = ['changed-catalog-concept'];
  assert.equal(practicedConcepts(state).has('changed-catalog-concept'), false);
  assert.ok(practicedConcepts(state).size > 0);
});
test('layout rejects duplicate or missing widgets and retains ordered sizes', () => {
  assert.deepEqual(layoutSchema.parse(defaultLayout), defaultLayout);
  assert.equal(layoutSchema.safeParse([...defaultLayout.slice(0, -1), defaultLayout[0]]).success, false);
  assert.equal(layoutSchema.safeParse(defaultLayout.slice(1)).success, false);
});
const feed: Feed = { id: randomUUID(), name: 'Fixture', endpoint: 'https://example.com/feed', topicIDs: ['go'], isEnabled: true };
test('RSS and Atom are parsed as plain text with safe links and unknown dates', () => {
  const at = '2026-10-02T02:00:00.000Z';
  const rss = '<rss><channel><item><title>A &amp; B</title><link>https://example.com/a?part=1&amp;utm_source=x</link><description><![CDATA[<b>Hello</b>]]></description></item><item><title>Bad</title><link>javascript:alert(1)</link></item></channel></rss>';
  const articles = parseFeed(rss, feed, at);
  assert.equal(articles.length, 1);
  assert.equal(articles[0].title, 'A & B');
  assert.equal(articles[0].summary, 'Hello');
  assert.equal(articles[0].publishedAt, null);
  const atom = '<feed><entry><title>Atom</title><link href="https://example.com/b" rel="alternate"/><updated>2026-10-01T00:00:00Z</updated></entry></feed>';
  assert.equal(parseFeed(atom, feed, at)[0].url, 'https://example.com/b');
  assert.throws(() => parseFeed('<!DOCTYPE foo [<!ENTITY x SYSTEM "file:///etc/passwd">]><rss/>', feed, at));
});
test('news deduplicates source contributions and bounds its cache without stripping meaningful query parameters', () => {
  assert.equal(canonicalURL('https://example.com/a?part=2&utm_campaign=x#foo'), 'https://example.com/a?part=2');
  const article = parseFeed('<rss><channel><item><title>One</title><link>https://example.com/one</link></item></channel></rss>', feed, '2026-10-02T00:00:00.000Z')[0];
  const newer = { ...article, feedIDs: ['second'], topicIDs: ['java'] };
  const merged = mergeArticles([article], [newer], start);
  assert.equal(merged.length, 1);
  assert.deepEqual(merged[0].feedIDs, [feed.id, 'second']);
  assert.deepEqual(merged[0].topicIDs, ['go', 'java']);
  assert.equal(mergeArticles([article], [], start + 31 * 86_400_000).length, 0);
});
test('feed access rejects loopback, private, metadata and mapped IPv6 addresses', () => {
  for (const address of ['127.0.0.1', '10.0.0.1', '172.16.0.1', '192.168.0.1', '169.254.169.254', '100.64.0.1', '::1', '::ffff:127.0.0.1', 'fe80::1', 'fd00::1', '2001:db8::1']) assert.equal(isPublicIP(address), false, address);
  for (const address of ['8.8.8.8', '1.1.1.1', '2606:4700:4700::1111']) assert.equal(isPublicIP(address), true);
});
test('an incomplete native export is rejected rather than silently defaulted', () => {
  assert.equal(nativeExportSchema.safeParse({ schemaVersion: 1, tasks: [] }).success, false);
});
