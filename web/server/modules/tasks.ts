import { Router } from 'express';
import { randomUUID } from 'node:crypto';
import { taskSchema, type Task } from '../../shared/schema';
import { Store } from '../store';
import { requireFound } from '../errors';

const draft = taskSchema.pick({ title: true, notes: true, dueAt: true, plannedDay: true });
export function tasksModule(store: Store): Router {
  const router = Router();
  store.init<Task[]>('tasks', []);
  router.get('/', (_req, res) => res.json(store.get<Task[]>('tasks')));
  router.post('/', (req, res) => {
    const task = taskSchema.parse({ ...draft.parse(req.body), id: randomUUID(), createdAt: new Date().toISOString(), completedAt: null });
    store.transaction(() => store.set('tasks', [...store.get<Task[]>('tasks'), task]));
    res.status(201).json(task);
  });
  router.patch('/:id', (req, res) => {
    const patch = draft.extend({ completedAt: taskSchema.shape.completedAt }).partial().parse(req.body);
    const task = store.transaction(() => {
      const tasks = store.get<Task[]>('tasks');
      const old = requireFound(tasks.find(x => x.id === req.params.id));
      const next = taskSchema.parse({ ...old, ...patch });
      store.set('tasks', tasks.map(x => x.id === old.id ? next : x));
      return next;
    });
    res.json(task);
  });
  router.delete('/:id', (req, res) => {
    store.transaction(() => {
      const tasks = store.get<Task[]>('tasks');
      requireFound(tasks.find(x => x.id === req.params.id));
      store.set('tasks', tasks.filter(x => x.id !== req.params.id));
    });
    res.status(204).end();
  });
  return router;
}
