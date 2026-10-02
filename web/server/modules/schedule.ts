import { Router } from 'express';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { blockSchema, type Block } from '../../shared/schema';
import { overlap } from '../../shared/dates';
import { Store } from '../store';
import { HttpError, requireFound } from '../errors';

const draft = z.object(blockSchema.shape).omit({ id: true }).extend({ allowOverlap: z.boolean().default(false) });
export function scheduleModule(store: Store): Router {
  const router = Router();
  store.init<Block[]>('schedule', []);
  router.get('/', (_req, res) => res.json(store.get<Block[]>('schedule')));
  router.post('/', (req, res) => {
    const { allowOverlap, ...input } = draft.parse(req.body);
    const block = blockSchema.parse({ ...input, id: randomUUID() });
    store.transaction(() => {
      const blocks = store.get<Block[]>('schedule');
      if (!allowOverlap && blocks.some(x => overlap(x, block))) throw new HttpError(409, 'This overlaps another block. Enable “Allow overlap” to save both.');
      store.set('schedule', [...blocks, block]);
    });
    res.status(201).json(block);
  });
  router.put('/:id', (req, res) => {
    const { allowOverlap, ...input } = draft.parse(req.body);
    const block = blockSchema.parse({ ...input, id: req.params.id });
    store.transaction(() => {
      const blocks = store.get<Block[]>('schedule');
      requireFound(blocks.find(x => x.id === block.id));
      if (!allowOverlap && blocks.some(x => x.id !== block.id && overlap(x, block))) throw new HttpError(409, 'This overlaps another block. Enable “Allow overlap” to save both.');
      store.set('schedule', blocks.map(x => x.id === block.id ? block : x));
    });
    res.json(block);
  });
  router.delete('/:id', (req, res) => {
    store.transaction(() => {
      const blocks = store.get<Block[]>('schedule');
      requireFound(blocks.find(x => x.id === req.params.id));
      store.set('schedule', blocks.filter(x => x.id !== req.params.id));
    });
    res.status(204).end();
  });
  return router;
}
