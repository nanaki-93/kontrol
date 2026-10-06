import { Router } from 'express';
import {
  EXPLORE_ERROR_HTTP_STATUS, exploreGenerateRequestSchema, exploreGenerateResponseSchema,
  exploreSearchRequestSchema, exploreSearchResponseSchema, exploreStatusResponseSchema, exploreTopicParamsSchema,
} from '../../shared/news-explore';
import { HttpError } from '../errors';
import { ExploreServiceError, type ExploreService } from '../news/explore';

export type ExploreRoutes = Pick<ExploreService, 'snapshot' | 'generate' | 'search'>;

// Only service-owned public errors cross this boundary. Unexpected exceptions
// fall through to the app's sanitized handler, never raw adapter/provider text.
async function publicResult<T>(run: () => T | Promise<T>): Promise<T> {
  try { return await run(); }
  catch (error) {
    if (error instanceof ExploreServiceError) throw new HttpError(EXPLORE_ERROR_HTTP_STATUS[error.code], error.message);
    throw error;
  }
}

/** Registered under News, behind the app's host/origin/client/JSON protections.
 * Recovery reads only process-local status. Neither registration nor GET can
 * check provider availability, invoke inference, or retrieve news.
 */
export function newsExploreModule(explore: ExploreRoutes): Router {
  const router = Router();
  router.get('/', async (_req, res) => {
    const status = await publicResult(() => explore.snapshot());
    res.json(exploreStatusResponseSchema.parse(status));
  });
  router.post('/generate', async (req, res) => {
    exploreGenerateRequestSchema.parse(req.body);
    const result = await publicResult(() => explore.generate());
    res.json(exploreGenerateResponseSchema.parse(result));
  });
  router.post('/:sessionID/topics/:topicID/search', async (req, res) => {
    const { sessionID, topicID } = exploreTopicParamsSchema.parse(req.params);
    const request = exploreSearchRequestSchema.parse(req.body);
    const result = await publicResult(() => explore.search(sessionID, topicID, request));
    res.json(exploreSearchResponseSchema.parse(result));
  });
  return router;
}
