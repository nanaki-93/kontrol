import { useId, useState, type ReactNode } from 'react';
import { ChevronDown, ChevronUp } from 'lucide-react';

export function JobSetupPanel({ name, eyebrow, title, icon, summary, defaultExpanded, status, feedback, children }: {
  name: 'cv' | 'preferences'; eyebrow: string; title: string; icon: ReactNode; summary: string;
  defaultExpanded: boolean; status?: string; feedback?: ReactNode; children: ReactNode;
}) {
  const contentId = useId(), headingId = useId();
  const storageKey = `kontrol:jobs:${name}:expanded`;
  const [expanded, setExpanded] = useState(() => {
    try {
      const saved = localStorage.getItem(storageKey);
      if (saved === 'true' || saved === 'false') return saved === 'true';
    } catch { /* The panel still works when browser storage is unavailable. */ }
    return defaultExpanded;
  });
  function toggle() {
    const next = !expanded;
    setExpanded(next);
    try { localStorage.setItem(storageKey, String(next)); }
    catch { /* Keep the choice for this visit. */ }
  }
  return <section className={`panel job-setup-panel job-${name}`} aria-labelledby={headingId}>
    <h2 className="job-setup-heading" id={headingId}>
      <button type="button" className="job-setup-toggle" aria-expanded={expanded} aria-controls={contentId} onClick={toggle}>
        <span className="accent-text" aria-hidden="true">{icon}</span>
        <span className="job-setup-title"><span className="eyebrow">{eyebrow}</span><span>{title}</span></span>
        <span className="job-setup-action">{expanded ? 'Minimize' : 'Expand'}{expanded ? <ChevronUp size={16} aria-hidden="true" /> : <ChevronDown size={16} aria-hidden="true" />}</span>
      </button>
    </h2>
    {!expanded && <p className="job-setup-summary">{summary}</p>}
    {status && <p className="job-setup-status"><span className="badge warning">{status}</span></p>}
    {/* Keep inputs and pending operations mounted when the panel is minimized. */}
    <div className="job-setup-body" id={contentId} hidden={!expanded}>{children}</div>
    {feedback}
  </section>;
}
