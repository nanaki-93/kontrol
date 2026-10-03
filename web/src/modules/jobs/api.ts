import { mutationOptions, queryOptions, useMutation, useQuery, useQueryClient, type QueryClient } from '@tanstack/react-query';
import { JOB_ANALYSIS_TIMEOUT_MS, JOB_SEARCH_TIMEOUT_MS, type JobsResponse, type JobsState } from '../../../shared/jobs';
import { api } from '../../lib/api';

export const jobsQueryOptions = queryOptions({
  queryKey: ['jobs'], queryFn: ({ signal }) => api<JobsResponse>('/jobs', 'GET', undefined, { signal, timeoutMs: 15_000 }), staleTime: 5000, retry: 1,
  refetchInterval: query => query.state.data?.activity ? 1500 : 30_000,
});
export const useJobs = () => useQuery(jobsQueryOptions);
type JobCommand = { path: string; method?: string; body: unknown };
export function jobCommandOptions(client: QueryClient) {
  return mutationOptions<JobsState, Error, JobCommand>({
    mutationKey: ['jobs-command'],
    onMutate: async ({ path, method }) => {
      await client.cancelQueries({ queryKey: ['jobs'] });
      const activity = path === '/analyze' ? 'analyzing' : path === '/search' ? 'searching' : path === '/cv' && method !== 'DELETE' ? 'uploading' : null;
      if (activity) client.setQueryData<JobsResponse>(['jobs'], state => state ? { ...state, activity } : state);
    },
    mutationFn: ({ path, method = 'POST', body }) => api('/jobs' + path, method, body, {
      timeoutMs: path === '/analyze' ? JOB_ANALYSIS_TIMEOUT_MS + 5000 : path === '/search' ? JOB_SEARCH_TIMEOUT_MS + 5000 : path === '/cv' && method !== 'DELETE' ? 35_000 : 15_000,
    }),
    onSettled: async data => {
      // A delayed status response must not overwrite a completed profile, or
      // keep a failed command pending while the server is unreachable.
      await client.cancelQueries({ queryKey: ['jobs'] });
      client.setQueryData<JobsResponse>(['jobs'], state => state ? { ...state, ...data, activity: null } : state);
      void client.invalidateQueries({ queryKey: ['jobs'] });
      void client.invalidateQueries({ queryKey: ['workspace'] });
    },
  });
}
export function useJobCommand() { return useMutation(jobCommandOptions(useQueryClient())); }
