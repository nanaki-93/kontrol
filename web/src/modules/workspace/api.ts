import { useMutation, useQueryClient } from '@tanstack/react-query';
import { api, useResource } from '../../lib/api';
import type { Workspace } from '../../../shared/workspace';

export const useWorkspace = () => useResource<Workspace>('workspace', '/workspace', 30_000);
export function useWorkspaceCommand() {
  const client = useQueryClient();
  return useMutation<Workspace, Error, { path: string; method?: string; body?: Record<string, unknown> }>({
    mutationKey: ['workspace-command'],
    mutationFn: async ({ path, method = 'POST', body = {} }) => {
      const state = client.getQueryData<Workspace>(['workspace']);
      if (!state) throw new Error('Wait for your workspace to load, then try again.');
      return api<Workspace>('/workspace' + path, method, { ...body, expectedRevision: state.revision });
    },
    onSuccess: async state => {
      await client.cancelQueries({ queryKey: ['workspace'] });
      client.setQueryData(['workspace'], state);
    },
    onError: () => { void client.invalidateQueries({ queryKey: ['workspace'] }); },
  });
}
