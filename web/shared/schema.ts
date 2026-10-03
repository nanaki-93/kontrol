import { z } from 'zod';

// Shared contracts are also the validation boundary for disk and imported data.
export const id = z.string().min(1).max(300).refine(value => value.trim() === value && value.normalize('NFC') === value);
export const text = z.string().max(500_000);
export const title = z.string().min(1).max(2_000).refine(value => !!value.trim(), 'Enter a title.');
export const instant = z.iso.datetime({ precision: 3 }).refine(value =>
  Number.isFinite(Date.parse(value)) && new Date(value).toISOString() === value, 'Invalid date.');
const nullableInstant = instant.nullable();
const stringList = z.array(id).max(10_000).refine(values => new Set(values).size === values.length, 'Duplicate IDs in a set.');
// Retained only to validate and preserve records in backups from earlier versions.
const plannedDaySchema = z.object({
  calendarIdentifier: z.enum(['gregorian', 'iso8601'], {
    error: 'Web import supports Gregorian/ISO planned dates. Other calendars need conversion before import.',
  }),
  year: z.number().int().min(1).max(9999),
  month: z.number().int().min(1).max(12),
  day: z.number().int().min(1).max(31),
  timeZoneID: id.refine(value => {
    try { new Intl.DateTimeFormat('en', { timeZone: value }); return true; } catch { return false; }
  }, 'Unknown time zone.'),
}).refine(value => {
  const date = new Date(0);
  date.setUTCFullYear(value.year, value.month - 1, value.day);
  return date.getUTCFullYear() === value.year && date.getUTCMonth() === value.month - 1 && date.getUTCDate() === value.day;
}, 'Invalid planned day.');

const taskSchema = z.object({
  id: z.uuid(), title, notes: text.nullable(), dueAt: nullableInstant,
  plannedDay: plannedDaySchema.nullable(), createdAt: instant, completedAt: nullableInstant,
});
const blockSchema = z.object({
  id: z.uuid(), title, startAt: instant, endAt: instant, note: text.nullable(),
  lessonID: id.nullable(), linkedTitleSnapshot: text.nullable(),
}).refine(value => value.endAt > value.startAt, 'The end must be after the start.');

export const sessionSchema = z.object({
  id: z.uuid(), state: z.enum(['running', 'paused', 'completed', 'ended']),
  plannedSeconds: z.number().int().positive(),
  accumulatedActiveSeconds: z.number().nonnegative(),
  activeSegmentStartedAt: nullableInstant, deadline: nullableInstant, pausedAt: nullableInstant,
  startedAt: instant, endedAt: nullableInstant, checkpointAt: instant,
  recoveryRequired: z.boolean(), linkedTaskID: z.uuid().nullable(), linkedLessonID: id.nullable(),
  linkedTitleSnapshot: text.nullable(),
}).superRefine((s, ctx) => {
  const fail = (message: string) => ctx.addIssue({ code: 'custom', message });
  if (s.accumulatedActiveSeconds > s.plannedSeconds || s.checkpointAt < s.startedAt) fail('Invalid Focus timing.');
  if (s.linkedTaskID && s.linkedLessonID) fail('A Focus session can link to a task or a lesson.');
  if (s.state === 'running') {
    if (!s.activeSegmentStartedAt || !s.deadline || s.pausedAt || s.endedAt || s.recoveryRequired ||
        s.accumulatedActiveSeconds >= s.plannedSeconds) fail('Invalid running session.');
    else if (s.checkpointAt < s.activeSegmentStartedAt || Math.abs(Date.parse(s.deadline) - Date.parse(s.activeSegmentStartedAt) -
      (s.plannedSeconds - s.accumulatedActiveSeconds) * 1000) > 2) fail('Invalid Focus deadline.');
  } else if (s.state === 'paused') {
    if (!s.pausedAt || s.activeSegmentStartedAt || s.deadline || s.endedAt ||
      s.accumulatedActiveSeconds >= s.plannedSeconds || s.pausedAt < s.startedAt || s.pausedAt > s.checkpointAt) fail('Invalid paused session.');
  } else {
    if (!s.endedAt || s.activeSegmentStartedAt || s.deadline || s.pausedAt || s.recoveryRequired) fail('Invalid ended session.');
    if (s.state === 'completed' && s.accumulatedActiveSeconds !== s.plannedSeconds) fail('Invalid completed duration.');
    if (s.endedAt && (s.endedAt < s.startedAt || s.endedAt > s.checkpointAt)) fail('Invalid Focus end time.');
    if (s.state === 'ended' && s.accumulatedActiveSeconds >= s.plannedSeconds) fail('An ended-early session must have time remaining.');
  }
});

const provenanceSchema = z.object({
  schemaVersion: z.literal(1), attribution: text.nullable(),
  generation: z.object({
    provider: id, requestedModel: id, returnedModel: id.nullable(), generatedAt: instant,
    operationID: z.uuid(), requestSchemaVersion: z.number().int(), objectiveRegistryVersion: z.number().int(),
  }).nullable(),
});
export const definitionSchema = z.object({
  id, objectiveKey: id, objective: text, title, topicID: id, subtopicID: id,
  conceptIDs: stringList.min(1), difficulty: z.enum(['basic', 'intermediate', 'advanced']),
  format: z.enum(['learn', 'code', 'question', 'design']), estimatedMinutes: z.number().int().positive(),
  prerequisiteConceptIDs: stringList, explanation: text, workedExample: text, exercise: text,
  referenceAnswer: text, selfCheckCriteria: z.array(text), contentVersion: z.number().int().positive(),
  normalizedContentHash: z.string().regex(/^sha256:[a-f0-9]{64}$/), source: z.enum(['seed', 'generated']), provenance: provenanceSchema.nullable(),
});
export const completedContentSchema = definitionSchema.pick({
  title: true, objectiveKey: true, conceptIDs: true, difficulty: true, format: true,
  explanation: true, workedExample: true, exercise: true, referenceAnswer: true, selfCheckCriteria: true,
});
export const attemptSchema = z.object({
  id: z.uuid(), lessonID: id, contentVersion: z.number().int().positive(), answerDraft: text,
  revision: z.number().int().nonnegative(), solutionRevealedAt: nullableInstant,
  selfCheckAcknowledgedAt: nullableInstant, completedAt: nullableInstant,
  pinnedContent: z.object({ envelopeVersion: z.literal(1), definition: definitionSchema }).nullable(),
  completedContentSnapshot: completedContentSchema.nullable(),
});
export const progressSchema = z.object({
  lessonID: id, status: z.enum(['available', 'started', 'completed', 'dismissed']),
  firstShownAt: nullableInstant, startedAt: nullableInstant, completedAt: nullableInstant,
  dismissedAt: nullableInstant, lastOpenedAt: nullableInstant,
});
export const learningSchema = z.object({
  topics: z.array(z.object({ id, name: title })),
  subtopics: z.array(z.object({ id, topicID: id, name: title })),
  concepts: z.array(z.object({ id, subtopicID: id, name: title, prerequisiteConceptIDs: stringList })),
  definitions: z.array(definitionSchema), progress: z.array(progressSchema), attempts: z.array(attemptSchema),
  slots: z.array(z.object({
    key: id, topicID: id, slotIndex: z.number().int().min(0).max(3), lessonID: id, assignedAt: instant,
  })),
  terminalRecords: z.array(z.object({
    schemaVersion: z.literal(1), lessonID: id, provenance: id, title: text.nullable(),
    topicID: id.nullable(), subtopicID: id.nullable(), contentVersion: z.number().int().positive().nullable(),
    objectiveKey: id.nullable(), conceptIDs: stringList.nullable(), normalizedContentHash: id.nullable(),
    format: id.nullable(), dismissalTimeDefinition: definitionSchema.nullable(),
  })),
  catalogMembership: z.array(z.object({
    schemaVersion: z.literal(1), catalogID: id, catalogVersion: z.number().int().positive(),
    topicIDs: stringList, subtopicIDs: stringList, conceptIDs: stringList, seededLessonIDs: stringList,
  })),
});
export const feedSchema = z.object({
  id: z.uuid(), name: title, endpoint: z.url(), topicIDs: stringList, isEnabled: z.boolean(),
});
export const feedPreferencesSchema = z.object({ selectedTopicIDs: stringList, feeds: z.array(feedSchema) });
export const generalPreferencesSchema = z.object({
  schemaVersion: z.literal(1), focusDefaultMinutes: z.number().int().min(1).max(1440),
  textSize: z.enum(['system', 'large']), reduceMotion: z.enum(['system', 'reduce']),
  ai: z.object({ enabled: z.boolean(), providerID: id, modelID: id.nullable() }),
});
export const nativeExportSchema = z.object({
  schemaVersion: z.literal(1), exportedAt: instant, appVersion: title, tasks: z.array(taskSchema),
  blocks: z.array(blockSchema), sessions: z.array(sessionSchema), learning: learningSchema,
  feedPreferences: feedPreferencesSchema, generalPreferences: generalPreferencesSchema,
}).superRefine((data, ctx) => {
  const unique = (values: string[], name: string) => {
    if (new Set(values).size !== values.length) ctx.addIssue({ code: 'custom', message: 'Duplicate ' + name + '.' });
  };
  unique(data.tasks.map(x => x.id.toLowerCase()), 'task IDs');
  unique(data.blocks.map(x => x.id.toLowerCase()), 'block IDs');
  unique(data.sessions.map(x => x.id.toLowerCase()), 'Focus IDs');
  unique(data.feedPreferences.feeds.map(x => x.id.toLowerCase()), 'feed IDs');
  for (const name of ['topics', 'subtopics', 'concepts', 'definitions', 'attempts'] as const) {
    unique(data.learning[name].map(x => x.id.normalize('NFC')), name);
  }
  for (const name of ['progress', 'terminalRecords'] as const) unique(data.learning[name].map(x => x.lessonID), name);
  unique(data.learning.slots.map(x => x.topicID + ':' + x.slotIndex), 'slot positions');
  unique(data.learning.slots.map(x => x.key), 'slot keys');
  unique(data.learning.slots.map(x => x.lessonID), 'slotted lessons');
  unique(data.learning.catalogMembership.map(x => x.catalogID), 'catalog membership');
  for (const attempt of data.learning.attempts) {
    if (attempt.pinnedContent && (attempt.pinnedContent.definition.id !== attempt.lessonID ||
      attempt.pinnedContent.definition.contentVersion !== attempt.contentVersion)) {
      ctx.addIssue({ code: 'custom', message: 'A saved lesson pin does not match its attempt.' });
    }
  }
  const activeAttempts = data.learning.attempts.filter(a => !a.completedAt);
  unique(activeAttempts.map(x => x.lessonID), 'active lesson attempts');
  if (data.sessions.filter(x => ['running', 'paused'].includes(x.state)).length > 1) {
    ctx.addIssue({ code: 'custom', message: 'Only one active Focus session is allowed.' });
  }
});

export const widgetIDs = ['focus', 'learning', 'projects', 'news', 'jobs'] as const;
export const layoutSchema = z.array(z.object({
  id: z.enum(widgetIDs), visible: z.boolean(), width: z.enum(['normal', 'wide']),
})).length(widgetIDs.length).refine(items => new Set(items.map(x => x.id)).size === widgetIDs.length);
// Remove retired widgets from complete six/seven-widget layouts. Older backups
// also gain JOB; all remaining order, width and visibility choices are preserved.
const legacyWidgetIDs = ['tasks', 'schedule', 'focus', 'learning', 'projects', 'news'] as const;
const legacyLayoutSchema = z.array(z.object({
  id: z.enum([...legacyWidgetIDs, 'jobs']), visible: z.boolean(), width: z.enum(['normal', 'wide']),
})).min(6).max(7).refine(items => {
  const ids = new Set(items.map(item => item.id));
  return ids.size === items.length && legacyWidgetIDs.every(id => ids.has(id));
}).transform(items => {
  const remaining = items.filter((item): item is Layout[number] => item.id !== 'tasks' && item.id !== 'schedule');
  return remaining.some(item => item.id === 'jobs') ? remaining :
    [...remaining, { id: 'jobs' as const, visible: true, width: 'wide' as const }];
}).pipe(layoutSchema);
export const compatibleLayoutSchema = z.union([
  layoutSchema,
  legacyLayoutSchema,
]);

export type Task = z.infer<typeof taskSchema>;
export type Block = z.infer<typeof blockSchema>;
export type Session = z.infer<typeof sessionSchema>;
export type Definition = z.infer<typeof definitionSchema>;
export type Attempt = z.infer<typeof attemptSchema>;
export type Learning = z.infer<typeof learningSchema>;
export type Feed = z.infer<typeof feedSchema>;
export type FeedPreferences = z.infer<typeof feedPreferencesSchema>;
export type Preferences = z.infer<typeof generalPreferencesSchema>;
export type NativeExport = z.infer<typeof nativeExportSchema>;
export type Layout = z.infer<typeof layoutSchema>;
export type WidgetID = typeof widgetIDs[number];
export const defaultLayout: Layout = (['learning', 'news', 'jobs', 'focus', 'projects'] as const)
  .map(id => ({ id, visible: id !== 'focus' && id !== 'projects', width: id === 'jobs' ? 'wide' : 'normal' }));
export const defaultPreferences: Preferences = {
  schemaVersion: 1, focusDefaultMinutes: 25, textSize: 'system', reduceMotion: 'system',
  ai: { enabled: false, providerID: 'openai', modelID: null },
};

export interface ProjectReference { id: string; path: string; name: string; manifestID: string }
export interface Feature {
  id: string; title: string; status: 'planned' | 'ready' | 'active' | 'blocked' | 'completed';
  priority: 'high' | 'medium' | 'low'; effort: 'small' | 'medium' | 'large';
  depends_on: string[]; areas: string[]; completed_at: string | null;
  body: string; file: string; digest: string;
}
export interface ProjectInspection {
  reference: ProjectReference;
  manifest: { id: string; name: string; description: string; stack: string[]; goals: string[]; current_focus: string[] } | null;
  features: Feature[]; candidates: string[];
  roadmap: { id: string; title: string; status: string }[];
  context: string | null; rules: string | null; errors: string[];
}
export interface Article {
  id: string; title: string; url: string; summary: string; publishedAt: string | null;
  fetchedAt: string; feedIDs: string[]; topicIDs: string[]; source: string;
}
export interface NewsState {
  preferences: FeedPreferences; articles: Article[]; lastRefreshAt: string | null; errors: Record<string, string>;
}
