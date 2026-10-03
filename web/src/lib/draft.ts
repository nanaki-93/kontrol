import { useEffect, useState } from 'react';

export interface Draft<T> { value: T; baseline: T; revision: string }
const equal = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);
export function createDraft<T>(value: T, revision: string): Draft<T> { return { value, baseline: value, revision }; }
export function refreshDraft<T>(draft: Draft<T>, saved: T, revision: string): Draft<T> {
  if (equal(draft.value, draft.baseline) || equal(draft.value, saved)) return createDraft(saved, revision);
  // Unrelated server updates can advance the revision without replacing edits.
  if (equal(draft.baseline, saved)) return { ...draft, revision };
  return draft;
}
export function useDraft<T>(saved: T, revision: string) {
  const [draft, setDraft] = useState(() => createDraft(saved, revision));
  const savedKey = JSON.stringify(saved);
  useEffect(() => { setDraft(current => refreshDraft(current, saved, revision)); }, [savedKey, revision]);
  return {
    value: draft.value, revision: draft.revision,
    dirty: !equal(draft.value, draft.baseline), conflict: !equal(draft.baseline, saved),
    edit: (value: T) => setDraft(current => ({ ...current, value })),
    accept: (value: T, revision: string) => setDraft(createDraft(value, revision)),
    reload: () => setDraft(createDraft(saved, revision)),
    keep: () => setDraft(current => ({ ...current, baseline: saved, revision })),
  };
}
