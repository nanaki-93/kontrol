import { lazy, type ComponentType, type LazyExoticComponent } from 'react';
import { CheckSquare2, CalendarDays, Timer, BookOpen, FolderGit2, Rss, BriefcaseBusiness, type LucideIcon } from 'lucide-react';
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
  { id: 'tasks', title: 'Tasks', widgetTitle: 'On your mind', description: 'Today’s tasks and quick capture', icon: CheckSquare2,
    page: lazy(() => import('../modules/tasks').then(m => ({ default: m.TasksPage }))),
    widget: lazy(() => import('../modules/tasks').then(m => ({ default: m.TasksWidget }))) },
  { id: 'schedule', title: 'Planner', widgetTitle: 'The shape of your day', description: 'A little structure for today', icon: CalendarDays,
    page: lazy(() => import('../modules/schedule').then(m => ({ default: m.SchedulePage }))),
    widget: lazy(() => import('../modules/schedule').then(m => ({ default: m.ScheduleWidget }))) },
  { id: 'focus', title: 'Focus', widgetTitle: 'A moment of focus', description: 'One thing at a time', icon: Timer,
    page: lazy(() => import('../modules/focus').then(m => ({ default: m.FocusPage }))),
    widget: lazy(() => import('../modules/focus').then(m => ({ default: m.FocusWidget }))) },
  { id: 'learning', title: 'Learning', widgetTitle: 'Stay a little curious', description: 'Your next small discovery', icon: BookOpen,
    page: lazy(() => import('../modules/learning').then(m => ({ default: m.LearningPage }))),
    widget: lazy(() => import('../modules/learning').then(m => ({ default: m.LearningWidget }))) },
  { id: 'projects', title: 'Projects', widgetTitle: 'Work in motion', description: 'Your projects and next steps', icon: FolderGit2,
    page: lazy(() => import('../modules/projects').then(m => ({ default: m.ProjectsPage }))),
    widget: lazy(() => import('../modules/projects').then(m => ({ default: m.ProjectsWidget }))) },
  { id: 'news', title: 'News', widgetTitle: 'Worth a read', description: 'Specific interests, across sources', icon: Rss,
    page: lazy(() => import('../modules/news').then(m => ({ default: m.NewsPage }))),
    widget: lazy(() => import('../modules/news').then(m => ({ default: m.NewsWidget }))) },
  { id: 'jobs', title: 'JOB', widgetTitle: 'Your next opportunity', description: 'Job offers matched to your CV', icon: BriefcaseBusiness,
    page: lazy(() => import('../modules/jobs').then(m => ({ default: m.JobsPage }))),
    widget: lazy(() => import('../modules/jobs').then(m => ({ default: m.JobsWidget }))) },
];
