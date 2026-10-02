import { Component, type ReactNode } from 'react';
import { AlertCircle, ArrowUpRight, LoaderCircle } from 'lucide-react';

export function ErrorMessage({ error }: { error: unknown }) {
  if (!error) return null;
  return <div className="error-message" role="alert"><AlertCircle size={17} /><span>{error instanceof Error ? error.message : String(error)}</span></div>;
}
export function Loading() { return <div className="loading" role="status"><LoaderCircle size={18} className="spin" /> Loading your workspace…</div>; }
export function Empty({ title, children, action }: { title: string; children?: ReactNode; action?: ReactNode }) {
  return <div className="empty"><div className="empty-mark" aria-hidden="true">⌁</div><h3>{title}</h3>{children && <p>{children}</p>}{action}</div>;
}
export function PageHeader({ eyebrow, title, description, action }: { eyebrow?: string; title: string; description: string; action?: ReactNode }) {
  return <header className="page-header"><div>{eyebrow && <p className="eyebrow">{eyebrow}</p>}<h1>{title}</h1><p>{description}</p></div>{action && <div className="header-actions">{action}</div>}</header>;
}
export function Badge({ children, tone = '' }: { children: ReactNode; tone?: string }) {
  return <span className={'badge ' + tone}>{children}</span>;
}
export function SectionTitle({ children, meta }: { children: ReactNode; meta?: ReactNode }) {
  return <div className="section-title"><h2>{children}</h2>{meta}</div>;
}
export function OpenLink({ route, children = 'Open module' }: { route: string; children?: ReactNode }) {
  return <a className="text-link" href={'#/' + route}>{children}<ArrowUpRight size={14} /></a>;
}
export function Confirm({ title, description, onConfirm, onCancel, pending = false, label = 'Confirm' }: {
  title: string; description: string; onConfirm: () => void; onCancel: () => void; pending?: boolean; label?: string;
}) {
  return <div className="confirmation" role="group" aria-label={title}>
    <strong>{title}</strong><p>{description}</p><div className="actions">
      <button className="button danger" disabled={pending} onClick={onConfirm}>{pending ? 'Working…' : label}</button>
      <button className="button secondary" disabled={pending} onClick={onCancel}>Cancel</button>
    </div>
  </div>;
}
export class ModuleBoundary extends Component<{ children: ReactNode }, { error: boolean }> {
  state = { error: false };
  static getDerivedStateFromError() { return { error: true }; }
  render() {
    if (this.state.error) return <div className="empty"><h3>This module could not be displayed.</h3><p>Your saved data is still on disk.</p><button className="button secondary" onClick={() => this.setState({ error: false })}>Try again</button></div>;
    return this.props.children;
  }
}
export function formatDate(value: string): string {
  return new Date(value).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}
export function formatTime(value: string): string {
  return new Date(value).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
}
