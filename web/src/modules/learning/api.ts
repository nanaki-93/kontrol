import type { Learning } from '../../../shared/schema';
import { useResource } from '../../lib/api';
export const useLearning = () => useResource<Learning>('learning', '/learning');
