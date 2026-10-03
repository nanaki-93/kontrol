import { useQuery } from '@tanstack/react-query';
import { useMemo } from 'react';
import type { NewsResponse } from '../../../shared/news';
import type { Workspace } from '../../../shared/workspace';
import { briefingStories } from '../../../shared/briefing';
import { api } from '../../lib/api';
export const useNews = () => useQuery<NewsResponse, Error>({
  queryKey: ['news'], queryFn: () => api<NewsResponse>('/news'), staleTime: 5000, retry: 1,
  refetchInterval: query => query.state.data?.activity.discovering || query.state.data?.activity.refreshingFeeds ? 1500 : 15_000,
});
export function useBriefingStories(news?: NewsResponse, workspace?: Workspace) {
  const minute = Math.floor(Date.now() / 60_000);
  return useMemo(() => news ? briefingStories(news, workspace) : [],
    [news?.articles, news?.preferences, news?.discovery, workspace?.profile.interests, workspace?.profile.targetRoles, minute]);
}
