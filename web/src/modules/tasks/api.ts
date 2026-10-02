import type { Task } from '../../../shared/schema';
import { useResource } from '../../lib/api';
export const useTasks = () => useResource<Task[]>('tasks', '/tasks');
