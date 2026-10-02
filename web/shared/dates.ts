import type { Task } from './schema';

export function dayKey(date = new Date()): string {
  return [date.getFullYear(), String(date.getMonth() + 1).padStart(2, '0'), String(date.getDate()).padStart(2, '0')].join('-');
}
export function plannedKey(task: Task): string | null {
  const p = task.plannedDay;
  return p ? [String(p.year).padStart(4, '0'), String(p.month).padStart(2, '0'), String(p.day).padStart(2, '0')].join('-') : null;
}
export function isTaskForDay(task: Task, day: string): boolean {
  return plannedKey(task) === day || !!(task.dueAt && dayKey(new Date(task.dueAt)) <= day);
}
export function dateInput(value: string | null): string {
  if (!value) return '';
  const date = new Date(value);
  return dayKey(date) + 'T' + String(date.getHours()).padStart(2, '0') + ':' + String(date.getMinutes()).padStart(2, '0');
}
export function fromDayInput(value: string): Task['plannedDay'] {
  if (!value) return null;
  const [year, month, day] = value.split('-').map(Number);
  return { year, month, day, calendarIdentifier: 'gregorian', timeZoneID: Intl.DateTimeFormat().resolvedOptions().timeZone };
}
export function overlap(a: { startAt: string; endAt: string }, b: { startAt: string; endAt: string }): boolean {
  return a.startAt < b.endAt && b.startAt < a.endAt;
}
