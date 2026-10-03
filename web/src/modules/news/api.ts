import { useIsMutating, useQuery } from '@tanstack/react-query';
import { useMemo } from 'react';
import type { NewsResponse } from '../../../shared/news';
import type { Workspace } from '../../../shared/workspace';
import { briefingStories } from '../../../shared/briefing';
import { api } from '../../lib/api';
export function useNews() {
  const pending = useIsMutating({ mutationKey: ['command', 'news'] }) > 0;
  return useQuery<NewsResponse, Error>({
    queryKey: ['news'], queryFn: ({ signal }) => api<NewsResponse>('/news', 'GET', undefined, { signal }), staleTime: 5000, retry: 1,
    refetchInterval: query => pending || query.state.data?.activity.discovering || query.state.data?.activity.refreshingFeeds ? 1500 : 60_000,
  });
}
export function useBriefingStories(news?: NewsResponse, workspace?: Workspace) {
  const minute = Math.floor(Date.now() / 60_000);
  return useMemo(() => news ? briefingStories(news, workspace) : [],
    [news?.articles, news?.preferences, news?.discovery, workspace?.profile.interests, workspace?.profile.targetRoles, minute]);
}
