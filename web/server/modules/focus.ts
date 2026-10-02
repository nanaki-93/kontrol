import { Router } from 'express';
import { randomUUID } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import { z } from 'zod';
import { sessionSchema, type Session, type Task } from '../../shared/schema';
import { Store } from '../store';
import { HttpError, requireFound } from '../errors';

export function activeSeconds(session: Session, now: number): number {
  const elapsed = session.activeSegmentStartedAt ? Math.max(0, now - Date.parse(session.activeSegmentStartedAt)) / 1000 : 0;
  return Math.min(session.plannedSeconds, session.accumulatedActiveSeconds + elapsed);
}
export function transition(session: Session, action: 'reconcile' | 'pause' | 'resume' | 'end', now: number): Session {
  if (session.state === 'completed' || session.state === 'ended') return session;
  const s = { ...session };
  const at = new Date(Math.max(now, Date.parse(s.startedAt))).toISOString();
  if (s.state === 'running' && now < Date.parse(s.checkpointAt) - 1000) {
    return { ...s, state: 'paused', activeSegmentStartedAt: null, deadline: null,
      pausedAt: s.checkpointAt, recoveryRequired: true };
  }
  const seconds = activeSeconds(s, now);
  if (seconds >= s.plannedSeconds || action === 'end') {
    return { ...s, state: seconds >= s.plannedSeconds ? 'completed' : 'ended',
      accumulatedActiveSeconds: seconds, activeSegmentStartedAt: null, deadline: null, pausedAt: null,
      checkpointAt: at, endedAt: seconds >= s.plannedSeconds ? s.deadline ?? at : at, recoveryRequired: false };
  }
  if (action === 'pause' && s.state === 'running') {
    return { ...s, state: 'paused', accumulatedActiveSeconds: seconds, activeSegmentStartedAt: null,
      deadline: null, pausedAt: at, checkpointAt: at };
  }
  if (action === 'resume' && s.state === 'paused') {
    return { ...s, state: 'running', activeSegmentStartedAt: at, pausedAt: null,
      deadline: new Date(Date.parse(at) + (s.plannedSeconds - seconds) * 1000).toISOString(),
      checkpointAt: at, recoveryRequired: false };
  }
  return s;
}

export function focusModule(store: Store, clock?: () => number): Router {
  const router = Router();
  store.init<Session[]>('focus', []);
  // Monotonic during one process lifetime; wall time is sampled on restart.
  const wallAnchor = Date.now(), monotonicAnchor = performance.now();
  const now = clock ?? (() => Math.round(wallAnchor + performance.now() - monotonicAnchor));
  function reconcile(): Session[] {
    return store.transaction(() => {
      const old = store.get<Session[]>('focus');
      const next = old.map(s => transition(s, 'reconcile', now()));
      if (JSON.stringify(old) !== JSON.stringify(next)) store.set('focus', next);
      return next;
    });
  }
  router.get('/', (_req, res) => res.json({ sessions: reconcile(), serverNow: now() }));
  router.post('/', (req, res) => {
    const input = z.object({ minutes: z.number().int().min(1).max(1440), taskID: z.uuid().nullable() }).parse(req.body);
    reconcile();
    const session = store.transaction(() => {
      const sessions = store.get<Session[]>('focus');
      if (sessions.some(s => s.state === 'running' || s.state === 'paused')) throw new HttpError(409, 'Finish the active session first.');
      const task = input.taskID ? requireFound(store.get<Task[]>('tasks').find(t => t.id === input.taskID), 'The linked task no longer exists.') : null;
      const timestamp = now(), at = new Date(timestamp).toISOString();
      const session = sessionSchema.parse({
        id: randomUUID(), state: 'running', plannedSeconds: input.minutes * 60,
        accumulatedActiveSeconds: 0, activeSegmentStartedAt: at, deadline: new Date(timestamp + input.minutes * 60_000).toISOString(),
        pausedAt: null, startedAt: at, endedAt: null, checkpointAt: at, recoveryRequired: false,
        linkedTaskID: task?.id ?? null, linkedLessonID: null, linkedTitleSnapshot: task?.title ?? null,
      });
      store.set('focus', [...sessions, session]);
      return session;
    });
    res.status(201).json(session);
  });
  router.post('/:id/:action', (req, res) => {
    const action = z.enum(['pause', 'resume', 'end']).parse(req.params.action);
    const next = store.transaction(() => {
      const sessions = store.get<Session[]>('focus');
      const session = requireFound(sessions.find(s => s.id === req.params.id));
      const next = sessionSchema.parse(transition(session, action, now()));
      store.set('focus', sessions.map(s => s.id === session.id ? next : s));
      return next;
    });
    res.json(next);
  });
  return router;
}
