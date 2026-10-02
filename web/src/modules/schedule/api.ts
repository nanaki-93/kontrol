import type { Block } from '../../../shared/schema';
import { useResource } from '../../lib/api';
export const useSchedule = () => useResource<Block[]>('schedule', '/schedule');
