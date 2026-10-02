import { useState, type FormEvent } from 'react';
import { FolderGit2, Plus, RefreshCw, ArrowUpRight, Check, Undo2, Unplug } from 'lucide-react';
import type { ProjectInspection, Feature } from '../../../shared/schema';
import { useCommand } from '../../lib/api';
import { useProjects } from './api';
import { PageHeader, Empty, ErrorMessage, Loading, Badge, Confirm, SectionTitle } from '../../components/ui';

export function ProjectsWidget() {
  const query = useProjects();
  if (query.isPending) return <Loading />;
  if (query.error) return <ErrorMessage error={query.error} />;
  return query.data.length ? <ul className="project-widget-list">{query.data.map(project => {
    const done = project.features.filter(f => f.status === 'completed').length;
    const next = project.features.find(f => f.id === project.candidates[0]);
    return <li key={project.reference.id}><a href={'#/projects?project=' + project.reference.id}><div className="row-spread"><FolderGit2 size={18} /><ArrowUpRight size={16} /></div>
      <h3>{project.manifest?.name ?? project.reference.name}</h3><p>{next?.title ?? (project.errors.length ? 'Needs your attention' : 'No ready features')}</p>
      <div className="progress-track"><span style={{ width: (project.features.length ? done / project.features.length * 100 : 0) + '%' }} /></div>
      <div className="row-meta">{done} / {project.features.length} features complete{project.errors.length > 0 && ' · Validation issues'}</div></a></li>;
  })}</ul> : <Empty title="Bring your projects into view." action={<a className="button secondary" href="#/projects"><Plus size={15} /> Connect a project</a>}>Connect a folder with a .kontrol manifest to see what is ready to build.</Empty>;
}
function FeatureDetails({ feature, project, close }: { feature: Feature; project: ProjectInspection; close: () => void }) {
  const command = useCommand(['projects']);
  const [confirm, setConfirm] = useState(false), [canUndo, setCanUndo] = useState(false);
  const current = project.features.find(f => f.id === feature.id) ?? feature;
  return <div className="panel feature-detail"><div className="row-spread"><div className="actions"><Badge tone={current.status === 'completed' ? 'success' : ''}>{current.status}</Badge><Badge>{current.priority} priority</Badge><Badge>{current.effort} effort</Badge></div><button className="button secondary" onClick={close}>Close</button></div>
    <h2>{current.title}</h2><p className="mono muted">{current.file}</p>
    <p className="muted">Depends on: {current.depends_on.length ? current.depends_on.join(', ') : 'No dependencies'}</p>
    <div className="prose-text">{current.body}</div><ErrorMessage error={command.error} />
    {project.candidates.includes(current.id) && !confirm && <button className="button primary" onClick={() => setConfirm(true)}><Check size={16} /> Mark feature complete</button>}
    {confirm && <Confirm title="Complete this feature?" description={'This updates status and completed_at in ' + current.file + '. Source code and Git are unchanged.'} label="Complete feature" pending={command.isPending} onCancel={() => setConfirm(false)}
      onConfirm={() => command.mutate({ path: '/projects/' + project.reference.id + '/features/' + encodeURIComponent(current.id) + '/complete', body: { expectedDigest: current.digest } },
        { onSuccess: () => { setConfirm(false); setCanUndo(true); } })} />}
    {canUndo && <div className="success-note"><Check size={16} /> Feature updated.<button className="button secondary" disabled={command.isPending} onClick={() =>
      command.mutate({ path: '/projects/' + project.reference.id + '/features/' + encodeURIComponent(current.id) + '/undo' }, { onSuccess: () => setCanUndo(false) })}><Undo2 size={15} /> Undo completion</button></div>}
  </div>;
}
export function ProjectsPage() {
  const query = useProjects(), command = useCommand(['projects']);
  const [selected, setSelected] = useState<string | null>(new URLSearchParams(window.location.hash.split('?')[1]).get('project'));
  const [add, setAdd] = useState(false), [path, setPath] = useState(''), [remove, setRemove] = useState(false);
  const [feature, setFeature] = useState<Feature | null>(null);
  const [tab, setTab] = useState('features');
  const project = query.data?.find(p => p.reference.id === selected) ?? query.data?.[0];
  async function connect(e: FormEvent) {
    e.preventDefault();
    try { await command.mutateAsync({ path: '/projects', body: { path } }); setPath(''); setAdd(false); }
    catch { /* Keep path for correction. */ }
  }
  function select(id: string) { setSelected(id); setFeature(null); setRemove(false); }
  return <><PageHeader eyebrow="KEEP THE BIGGER PICTURE CLOSE" title="Projects" description="Your local repositories, with a clear next step."
    action={<><button className="button secondary" onClick={() => void query.refetch()} disabled={query.isFetching}><RefreshCw size={16} /> Refresh</button><button className="button primary" onClick={() => setAdd(!add)}><Plus size={17} /> Connect folder</button></>} />
    {add && <form className="panel editor" onSubmit={connect}><h2>Connect a local project</h2><p className="muted">Enter the folder containing .kontrol/project.yaml. Project files stay in that folder.</p>
      <label>Absolute folder path<input required value={path} onChange={e => setPath(e.target.value)} placeholder="/Users/you/Projects/my-project" /></label>
      <p className="footnote">The manifest uses schema_version: 1, id, and name. Features live in .kontrol/features/*.md. See the repository’s docs/examples/.kontrol for a complete example.</p>
      <ErrorMessage error={command.error} /><div className="actions"><button className="button primary" disabled={command.isPending}>Connect project</button><button className="button secondary" type="button" onClick={() => setAdd(false)}>Cancel</button></div></form>}
    <ErrorMessage error={query.error} />
    {query.isPending ? <Loading /> : project ? <div className="project-layout"><aside className="project-picker panel" aria-label="Connected projects">
      <p className="eyebrow">YOUR PROJECTS</p>{query.data?.map(p => <button key={p.reference.id} className={p.reference.id === project.reference.id ? 'selected' : ''} onClick={() => select(p.reference.id)}><FolderGit2 size={17} /><span>{p.manifest?.name ?? p.reference.name}</span>{p.errors.length > 0 && <span className="warning-text">!</span>}</button>)}
    </aside><div className="project-main"><div className="panel"><div className="row-spread"><Badge>LOCAL PROJECT</Badge><button className="text-link" onClick={() => setRemove(true)}><Unplug size={14} /> Disconnect</button></div>
      <h2 className="project-title">{project.manifest?.name ?? project.reference.name}</h2><p className="muted">{project.manifest?.description}</p>
      <p className="mono folder-path">{project.reference.path}</p><div className="actions">{project.manifest?.stack.map(s => <Badge key={s}>{s}</Badge>)}</div>
      {project.errors.length > 0 && <div className="error-message" role="alert"><div><strong>Some project files need attention</strong><ul>{project.errors.map((e, i) => <li key={i}>{e}</li>)}</ul><p>Counts include parsed feature files only; invalid dependencies are excluded from next steps.</p></div></div>}
      {remove && <Confirm title="Disconnect this project?" description="This removes its dashboard reference. All files in the folder stay in place." label="Disconnect" pending={command.isPending} onCancel={() => setRemove(false)}
        onConfirm={() => command.mutate({ path: '/projects/' + project.reference.id, method: 'DELETE' }, { onSuccess: () => { setSelected(null); setFeature(null); setRemove(false); } })} />}
      <ErrorMessage error={!add ? command.error : null} /></div>
      {feature && <FeatureDetails key={project.reference.id + feature.id} project={project} feature={feature} close={() => setFeature(null)} />}
      <div className="panel"><SectionTitle meta={<Badge>{project.candidates.length} ready</Badge>}>Up next</SectionTitle>
        {project.candidates.length ? <div className="next-features">{project.candidates.map((id, i) => {
          const f = project.features.find(f => f.id === id)!;
          return <button key={id} className="next-feature" onClick={() => setFeature(f)}><span className="feature-number">0{i + 1}</span><span><strong>{f.title}</strong><span className="row-meta">{f.priority} priority · {f.effort} effort</span></span><ArrowUpRight size={17} /></button>;
        })}</div> : <Empty title={project.features.length > 0 && project.features.every(f => f.status === 'completed') ? 'Every feature is complete.' : 'No ready features yet.'}>A feature is ready when its status is ready and its dependencies are completed.</Empty>}</div>
      <div className="panel"><div className="tabs">{['features', 'roadmap', 'context', 'rules'].map(name => <button key={name} className={name === tab ? 'active' : ''} onClick={() => setTab(name)}>{name}</button>)}</div>
        {tab === 'features' && <ul className="simple-list">{project.features.map(f => <li key={f.file}><button className="list-link" onClick={() => setFeature(f)}><strong>{f.title}</strong><span className="row-meta">{f.id}</span></button><Badge tone={f.status === 'completed' ? 'success' : ''}>{f.status}</Badge></li>)}</ul>}
        {tab === 'roadmap' && (project.roadmap.length ? <ul className="simple-list">{project.roadmap.map((m, i) => <li key={m.id + i}><strong>{m.title}</strong><Badge>{m.status}</Badge></li>)}</ul> : <Empty title="No roadmap file." />)}
        {(tab === 'context' || tab === 'rules') && <div className="prose-text">{project[tab] ?? 'No ' + tab + '.md file in this project.'}</div>}</div>
    </div></div> : <div className="panel"><Empty title="Your work has a home. Bring it here." action={<button className="button primary" onClick={() => setAdd(true)}><Plus size={16} /> Connect your first project</button>}>Kontrol reads the .kontrol files in your local repositories and surfaces the next three ready features.</Empty></div>}
  </>;
}
