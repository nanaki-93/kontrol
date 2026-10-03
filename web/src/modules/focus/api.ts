import type { Session } from '../../../shared/schema';
import { useQuery } from '@tanstack/react-query';
import { api, useResource } from '../../lib/api';
export const useFocus = () => useResource<{ sessions: Session[]; serverNow: number }>('focus', '/focus', 60_000);
export const useFocusStatus = () => useQuery<{ active: Session | null; serverNow: number }, Error>({
  queryKey: ['focus-status'], queryFn: ({ signal }) => api('/focus/status', 'GET', undefined, { signal }),
  staleTime: 5000, retry: 1,
  refetchInterval: query => query.state.data?.active?.state === 'running' ? 5000 : 30_000,
});
