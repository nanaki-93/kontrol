import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { canonicalURL, safeURL, calendarDay, emptyWorkspace, workspaceSchema, groupStories, layoutPresets,
  learningPaths, nextLesson, relatedLessons, dueReviews, lessonDefinition } from '../shared/workspace';
import { layoutSchema } from '../shared/schema';
import { initialLearning } from '../server/modules/learning';

test('saved links remove tracking without merging different offers or accepting executable URLs', () => {
  assert.equal(canonicalURL('https://example.com/job?utm_source=feed&id=1#top'), 'https://example.com/job?id=1');
  assert.notEqual(canonicalURL('https://example.com/job?id=1'), canonicalURL('https://example.com/job?id=2'));
  for (const url of ['javascript:alert(1)', 'file:///tmp/example', 'https://user:secret@example.com']) assert.equal(safeURL.safeParse(url).success, false);
  for (const date of ['2026-02-30', '2026-13-01', '2026-1-1']) assert.equal(calendarDay.safeParse(date).success, false);
  assert.equal(calendarDay.parse('2028-02-29'), '2028-02-29');
});
test('briefing groups similar dated coverage but does not invent events for undated or unrelated stories', () => {
  const article = (title: string, url: string, publishedAt: string | null = '2026-10-03T00:00:00.000Z') => ({ title, url, publishedAt });
  const groups = groupStories([
    article('Acme releases new compiler with faster memory allocation', 'https://a.example/1'),
    article('Acme releases new compiler with faster memory allocation today', 'https://b.example/2'),
    article('Acme releases new compiler with faster memory allocation', 'https://a.example/1?utm_source=x'),
    article('Acme releases new compiler with faster memory allocation', 'https://c.example/3', null),
    article('Another company announces a new remote engineering role', 'https://d.example/4'),
  ]);
  assert.equal(groups.length, 3); assert.equal(groups[0].related.length, 1);
  assert.equal(groups[1].lead.publishedAt, null);
});
test('learning paths reference real catalog objectives and every dashboard preset remains customizable', () => {
  const state = initialLearning();
  for (const path of learningPaths) for (const objective of path.objectives) assert.ok(state.definitions.some(d => d.objectiveKey === objective), objective);
  for (const layout of Object.values(layoutPresets)) assert.equal(layoutSchema.safeParse(layout).success, true);
  const workspace = emptyWorkspace(randomUUID()); workspace.profile.topicIDs = ['security'];
  assert.equal(nextLesson(state, workspace)?.topicID, 'security');
  const started = state.definitions.find(d => d.topicID === 'go')!;
  state.progress.push({ lessonID: started.id, status: 'started', startedAt: '2026-10-02T00:00:00.000Z', lastOpenedAt: '2026-10-02T00:00:00.000Z', firstShownAt: null, completedAt: null, dismissedAt: null });
  assert.equal(nextLesson(state, workspace)?.id, started.id);
});
test('skill suggestions use actual catalog topics and admit coverage gaps', () => {
  const state = initialLearning();
  assert.ok(relatedLessons(state, 'Go').every(d => d.topicID === 'go'));
  assert.ok(relatedLessons(state, 'System design').some(d => d.topicID === 'design'));
  assert.ok(relatedLessons(state, 'Performance').some(d => d.topicID === 'perf'));
  assert.equal(relatedLessons(state, 'Kubernetes').length, 0);
  assert.equal(relatedLessons(state, 'Python').length, 0);
});
test('reviews respect pinned content, due times, and self-assessment without creating mastery', () => {
  const state = initialLearning(), workspace = emptyWorkspace(randomUUID()), lesson = state.definitions[0], at = '2026-10-01T00:00:00.000Z';
  state.progress.push({ lessonID: lesson.id, status: 'completed', completedAt: at, startedAt: at, firstShownAt: at, lastOpenedAt: at, dismissedAt: null });
  state.attempts.push({ id: randomUUID(), lessonID: lesson.id, contentVersion: 1, answerDraft: 'Original practice', revision: 1, solutionRevealedAt: at, selfCheckAcknowledgedAt: at, completedAt: at,
    pinnedContent: { envelopeVersion: 1, definition: { ...lesson, title: 'Pinned original' } }, completedContentSnapshot: null });
  assert.equal(dueReviews(state, workspace, Date.parse(at)).length, 0);
  assert.equal(dueReviews(state, workspace, Date.parse(at) + 86_400_000).length, 1);
  assert.equal(lessonDefinition(state, lesson.id)?.title, 'Pinned original');
  workspace.reviews.push({ lessonID: lesson.id, nextAt: '2026-10-09T00:00:00.000Z', history: [{ at: '2026-10-02T00:00:00.000Z', rating: 'confident', response: 'Recall answer' }] });
  assert.equal(dueReviews(state, workspace, Date.parse('2026-10-03T00:00:00.000Z')).length, 0);
  assert.equal(state.attempts[0].answerDraft, 'Original practice');
  assert.equal(workspaceSchema.safeParse(workspace).success, true);
  state.attempts[0].pinnedContent = null;
  assert.equal(lessonDefinition(state, lesson.id), undefined, 'Never substitute current catalog content for missing historical content');
  assert.equal(dueReviews(state, workspace, Date.parse('2026-10-20T00:00:00.000Z')).length, 0);
});
