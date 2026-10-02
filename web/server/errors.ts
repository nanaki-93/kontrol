export class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
}
export function requireFound<T>(value: T | undefined, message = 'This item no longer exists.'): T {
  if (value === undefined) throw new HttpError(404, message);
  return value;
}
