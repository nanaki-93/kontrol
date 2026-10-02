import type { Preferences, Layout } from '../../../shared/schema';
import { useResource } from '../../lib/api';
export const useSettings = () => useResource<{ preferences: Preferences; layout: Layout; instanceID: string }>('settings', '/settings');
