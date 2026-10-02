import type { Session } from '../../../shared/schema';
import { useResource } from '../../lib/api';
export const useFocus = () => useResource<{ sessions: Session[]; serverNow: number }>('focus', '/focus', 5000);
