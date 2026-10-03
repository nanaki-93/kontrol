import { lazy, type ComponentType, type LazyExoticComponent } from 'react';
import { Timer, BookOpen, FolderGit2, Rss, BriefcaseBusiness, type LucideIcon } from 'lucide-react';
import type { WidgetID } from '../../shared/schema';

export interface DashboardModule {
  id: WidgetID;
  title: string;
  widgetTitle: string;
  description: string;
  icon: LucideIcon;
  page: LazyExoticComponent<ComponentType>;
  widget: LazyExoticComponent<ComponentType>;
}

// The shell only knows this manifest. Each module supplies a page and a widget;
// both use the same module API and query cache. No separate dashboard data model.
export const modules: DashboardModule[] = [
  { id: 'focus', title: 'Focus', widgetTitle: 'Focus timer', description: 'One thing at a time', icon: Timer,
    page: lazy(() => import('../modules/focus').then(m => ({ default: m.FocusPage }))),
    widget: lazy(() => import('../modules/focus').then(m => ({ default: m.FocusWidget }))) },
  { id: 'learning', title: 'Learning', widgetTitle: 'Continue learning', description: 'Your next lesson and review', icon: BookOpen,
    page: lazy(() => import('../modules/learning').then(m => ({ default: m.LearningPage }))),
    widget: lazy(() => import('../modules/learning').then(m => ({ default: m.LearningWidget }))) },
  { id: 'projects', title: 'Projects', widgetTitle: 'Practice in projects', description: 'Your projects and next steps', icon: FolderGit2,
    page: lazy(() => import('../modules/projects').then(m => ({ default: m.ProjectsPage }))),
    widget: lazy(() => import('../modules/projects').then(m => ({ default: m.ProjectsWidget }))) },
  { id: 'news', title: 'News', widgetTitle: 'Today’s briefing', description: 'Five relevant stories', icon: Rss,
    page: lazy(() => import('../modules/news').then(m => ({ default: m.NewsPage }))),
    widget: lazy(() => import('../modules/news').then(m => ({ default: m.NewsWidget }))) },
  { id: 'jobs', title: 'Jobs', widgetTitle: 'Opportunities & next steps', description: 'Discover, save, and prepare', icon: BriefcaseBusiness,
    page: lazy(() => import('../modules/jobs').then(m => ({ default: m.JobsPage }))),
    widget: lazy(() => import('../modules/jobs').then(m => ({ default: m.JobsWidget }))) },
];
