import { useQuery } from '@tanstack/react-query';
import type { NewsResponse } from '../../../shared/news';
import { api } from '../../lib/api';
export const useNews = () => useQuery<NewsResponse, Error>({
  queryKey: ['news'], queryFn: () => api<NewsResponse>('/news'), staleTime: 5000, retry: 1,
  refetchInterval: query => query.state.data?.activity.discovering || query.state.data?.activity.refreshingFeeds ? 1500 : 15_000,
});
