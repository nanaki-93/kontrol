import type { ProjectInspection } from '../../../shared/schema';
import { useResource } from '../../lib/api';
export const useProjects = () => useResource<ProjectInspection[]>('projects', '/projects');
