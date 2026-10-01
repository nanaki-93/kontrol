"""Planning-only HTML generator. Standard library; no app data, services or network.
Run from any directory with Python 3. Output is confined to this mockup directory.
"""
from pathlib import Path
import json
from html import escape

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
catalog = json.loads((REPO / 'Kontrol/Resources/starter-catalog.json').read_text())
# Illustrative selection, NOT the user's persisted assignment or progress.
topics = catalog['topics']
lessons = {t['id']: [x for x in catalog['lessons'] if x['topicID'] == t['id']][:4] for t in topics}
data = {k: [dict(title=x['title'], minutes=x['estimatedMinutes'], objective=x['objective'],
                  difficulty=x['difficulty'], format=x['format'], started=(k == 'go' and i == 0))
            for i, x in enumerate(v)] for k, v in lessons.items()}
CSS = '''
body { margin:0; background:var(--color-background); color:var(--color-text-primary); font:calc(var(--type-body)*var(--text-scale))/var(--leading-body) var(--font-mono); }
a { color:var(--color-accent); text-underline-offset:4px; } a.btn { text-decoration:none; }
h1 { font-size:calc(var(--type-page)*var(--text-scale)); line-height:var(--leading-tight); margin:0; }
h2 { font-size:calc(var(--type-section)*var(--text-scale)); font-weight:var(--weight-semibold); margin:0 0 var(--space-3); }
h3,p { margin:0 0 var(--space-2); } h3 { font-size:inherit; } small,.meta { font-size:calc(var(--type-metadata)*var(--text-scale)); color:var(--color-text-secondary); }
.mock-meta { display:flex; flex-wrap:wrap; gap:var(--space-4); padding:var(--space-3) var(--space-6); border-bottom:1px solid var(--color-border); font-size:var(--type-metadata); background:var(--color-raised-surface); }
.global { display:flex; flex-wrap:wrap; padding:0 var(--space-6); border-bottom:1px solid var(--color-border); gap:var(--space-2); }
.global a,.global span { flex:1; text-align:center; padding:var(--space-4) var(--space-2); color:var(--color-text-secondary); text-decoration:none; }
.global [aria-current] { color:var(--color-accent); border-bottom:2px solid var(--color-accent); }
.global span { opacity:.65; }
main { max-width:1280px; margin:auto; padding:var(--space-8); }
.page-header { margin-bottom:var(--space-8); } .actions { display:flex; flex-wrap:wrap; align-items:center; gap:var(--space-2); }
section { min-width:0; } .workspace { display:grid; grid-template-columns:180px minmax(0,1fr); gap:var(--space-8); }
.topic-nav { display:flex; flex-direction:column; gap:var(--space-2); }
.topic-nav .btn { justify-content:flex-start; } .topic-nav [aria-pressed=true] { border-left:4px solid var(--color-accent); color:var(--color-accent); }
.section-header { margin-bottom:var(--space-4); } .section-header h2 { margin:0; }
.section { margin-bottom:var(--space-8); } .reading { max-width:70ch; }
.layout-two { display:grid; grid-template-columns:minmax(0,1fr) minmax(0,1fr); gap:var(--space-8); }
.preview { background:var(--color-surface); border-radius:var(--radius-medium); padding:var(--space-6); align-self:start; }
.preview h2 { font-size:calc(var(--type-dialog)*var(--text-scale)); }
.preview .actions { margin-top:var(--space-6); } .list-button { width:100%; justify-content:flex-start; text-align:left; margin-bottom:var(--space-2); padding:var(--space-4); }
.list-button[aria-pressed=true] { border-left:4px solid var(--color-accent); }
.next-action-card { align-items:flex-start; } .next-action-card .actions { padding-top:var(--space-1); }
details { margin-top:var(--space-3); } summary { cursor:pointer; color:var(--color-text-secondary); min-height:32px; padding:var(--space-1) 0; }
details p { margin:var(--space-2) 0; } .section-border { padding-top:var(--space-6); border-top:1px solid var(--color-border); }
.route-row { display:flex; justify-content:space-between; gap:var(--space-4); flex-wrap:wrap; }
.error-banner,.empty-state { margin-bottom:var(--space-6); } .offline { margin-bottom:var(--space-6); }
.state-tools { padding:var(--space-3) var(--space-6); display:flex; flex-wrap:wrap; gap:var(--space-4); align-items:center; font-size:var(--type-metadata); }
select { font:inherit; background:var(--color-surface); color:var(--color-text-primary); padding:var(--space-2); border:1px solid var(--color-control-boundary); }
:focus-visible { outline:2px solid var(--color-focus-ring); outline-offset:3px; }
[hidden] { display:none !important; } dialog { background:var(--color-raised-surface); color:var(--color-text-primary); border:1px solid var(--color-control-boundary); border-radius:var(--radius-medium); max-width:520px; padding:var(--space-6); font:inherit; }
dialog::backdrop { background:rgb(0 0 0 / .7); } .large { --text-scale:1.3; }
.index-grid { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:var(--space-8); } .index-card { padding:var(--space-6); background:var(--color-surface); }
.index-card ul { padding-left:var(--space-6); } iframe { width:100%; height:420px; border:1px solid var(--color-border); margin-top:var(--space-4); }
@media(max-width:900px) { .layout-two { grid-template-columns:1fr; } .workspace { grid-template-columns:1fr; } .topic-nav { flex-direction:row; flex-wrap:wrap; } main { padding:var(--space-6); } .index-grid { grid-template-columns:1fr; } }
'''
features = [
 dict(title='Preserve drafts during navigation', meta='High priority · Small effort', objective='Keep unfinished answers when a destination change cannot be saved.'),
 dict(title='Export a local project summary', meta='Normal priority · Medium effort', objective='Prepare a readable summary from the selected project metadata.'),
 dict(title='Clarify dependency failures', meta='Normal priority · Small effort', objective='Show the dependency blocking a feature and its current status.')]


def btn(label, primary=False, note=None):
    return f'<button class="btn{ " btn--primary" if primary else ""}" data-note="{escape(note or label, quote=True)}">{escape(label)}</button>'


def link(label, href, primary=False):
    return f'<a class="btn{ " btn--primary" if primary else ""}" href="{href}">{label}</a>'


def fname(option, page, stress=False):
    return f'{option}-{page}{"-offline-large" if stress else ""}.html'


def heading(title, meta='', actions=''):
    return f'<header class="page-header"><div><h1>{title}</h1><p class="meta">{meta}</p></div><div class="actions">{actions}</div></header>'


def content(option, page, stress):
    offline = '<p class="offline meta">Offline · saved lessons and local planning remain available.</p>' if stress and page != 'projects' else ''
    if page == 'tasks':
        rows = ''
        for title, meta in [('Review retry behavior', 'Due today · 16:00'), ('Write release notes', 'Planned today')]:
            rows += '<article class="app-list-row"><div class="app-list-row__content"><h3>' + title + '</h3><p class="app-list-row__meta">' + meta + '</p><details><summary>Details &amp; actions</summary><p class="meta">Plan: 1 October 2026 · Gregorian · saved zone: Asia/Manila</p><div class="actions">' + btn('Edit', note='Open the existing task editor.') + btn('Delete', note='Keep the existing task-specific permanent-deletion confirmation.') + '</div></details></div>' + btn('Complete', note='Use the existing task completion action. This does not end Focus or complete a lesson.') + '</article>'
        return heading('Tasks', '', btn('Add task', True)) + '<div class="actions section">' + btn('Today · 2', True) + btn('Upcoming · 3') + btn('Completed · 8') + '</div><section><h2>Today</h2>' + rows + '</section>'
    if page == 'focus':
        return heading('Focus','Ready',btn('Sessions')) + '''<section class="preview reading"><h2 style="font-size:calc(var(--type-page)*2*var(--text-scale))">25:00</h2><p class="meta">No linked activity</p><div class="actions">''' + btn('Start', True, 'Start the existing Focus session with the selected duration and optional link; no lesson/task completion is implied.') + '''</div></section><section class="section-border reading"><h2>Duration</h2><div class="actions">''' + btn('15') + btn('25',True) + btn('50') + btn('Custom') + '''</div></section><details class="section-border reading"><summary>Link an activity (optional)</summary><label>Activity type <select id="activity-type"><option value="none">None</option><option value="task">Task</option><option value="lesson">Lesson</option></select></label><p id="task-link" hidden><label>Task <select><option>Review retry behavior</option><option>Write release notes</option></select></label></p><p id="lesson-link" hidden><label>Lesson <select><option>Stop a worker when its caller leaves</option><option>Design table-driven tests for boundary cases</option></select></label></p><p class="meta">Link one task or lesson. Finishing Focus does not complete it.</p></details><div class="section-border">''' + btn('Reset', note='Reset unsaved Focus configuration only; never reset an active session.') + '</div>'
    if page == 'news':
        warning = '<div class="error-banner"><div><strong>Offline · showing saved headlines</strong><details><summary>Feed details</summary><p>Example feed could not refresh. Saved headlines remain available.</p></details></div>' + btn('Refresh') + '</div>' if stress else ''
        rows=''
        for title,meta in [('A practical guide to Go cancellation','Go engineering · Today · Go'),('Designing dependable background work','Systems journal · Yesterday · System Design')]:
            rows+='<article class="app-list-row"><div class="app-list-row__content"><h3>'+title+'</h3><p class="app-list-row__meta">'+meta+'</p><details><summary>Summary</summary><p>Illustrative cached plain-text article summary.</p></details></div>'+btn('Read ↗',note='Open the existing validated source URL in the browser only on explicit Read.')+'</article>'
        return heading('News','Last updated 09:10',btn('Refresh')+btn('Topics & feeds'))+'<div class="actions section">'+btn('All',True)+btn('Go')+btn('System Design')+'</div>'+warning+'<section><h2>Headlines</h2>'+rows+'</section>'
    if page == 'settings':
        rows=''
        for title,summary in [('General','Focus: 25 min · System text and motion'),('AI lessons','Off · Not configured'),('News','7 topics · 7 feeds enabled'),('Project folders','1 connected folder'),('Local data','Export saved data')]:
            rows+='<article class="app-list-row"><div class="app-list-row__content"><h2>'+title+'</h2><p class="app-list-row__meta">'+summary+'</p></div>'+btn('Open',note='Open existing '+title+' Settings section with its own drafts, confirmations and failure handling.')+'</article>'
        return heading('Settings')+'<section class="reading">'+rows+'</section><p class="meta">Black / Red Terminal</p>'
    if page == 'learning':
        topics_html = ''.join(f'<button class="btn" data-topic="{t["id"]}" aria-pressed="{str(t["id"]=="go").lower()}">{escape(t["name"])}</button>' for t in topics)
        return heading('Learning', '', btn('History') + btn('Coverage')) + offline + f'''
        <div class="workspace"><aside><h2>Topics</h2><nav class="topic-nav" aria-label="Learning topics">{topics_html}</nav></aside>
        <section><div class="section-header"><h2 id="topic-title">Go</h2><span class="meta" id="choice-count">4 available</span></div>
        <div id="learning-items"></div>
        <section class="section-border"><div class="route-row"><h2>Saved work</h2>{btn('History')}</div>
        <p class="meta">No additional unfinished lessons.</p></section>
        <section class="section-border"><div class="route-row"><h2>More lessons</h2>{btn('Generate lesson', note='Generation opens the existing configuration and consent sheet. No request is sent by browsing.')}</div></section>
        </section></div>'''
    if page == 'projects':
        rows = ''.join(f'''<article class="next-action-card"><div class="next-action-card__content"><h3>{escape(f['title'])}</h3><p class="next-action-card__meta">{f['meta']}</p><details><summary>Details</summary><p>{escape(f['objective'])}</p>{btn('Mark complete', note='Explicit completion writes the selected feature file only; preserve current conflict checks and Undo.')}</details></div><div class="actions">{btn('View', True, 'Open this feature in its existing detail route.')}</div></article>''' for f in features)
        if option == 'b':
            rows = '<div class="layout-two"><div>' + ''.join(f'<button class="btn list-button" data-feature="{i}" aria-pressed="{str(i==0).lower()}"><span>{escape(f["title"])}<br><small>{f["meta"]}</small></span></button>' for i,f in enumerate(features)) + '</div><article class="preview" id="feature-preview"></article></div>'
        stale = '<div class="error-banner"><div><strong>Project changed · refresh needed</strong><p>Previous details are available. Next features are unavailable until refreshed.</p></div>' + btn('Refresh', note='Refresh reads the project. It never retries completion automatically.') + '</div>' if stress else ''
        body = '<div class="empty-state">Refresh to load current next features.</div>' if stress else rows
        return heading('Projects', '', btn('Add folder')) + f'''<div class="workspace"><aside><h2>Folders</h2><button class="btn list-button" aria-pressed="true">Developer workspace</button></aside><section>
        <div class="section-header"><h2>Developer workspace</h2><div class="actions">{btn('Refresh')}{btn('Project details')}</div></div>
        {stale}<p class="meta">{'Last known: ' if stress else ''}8 of 15 features completed</p><section class="section"><h2>Next features</h2>{body}</section>
        <details class="section-border"><summary>Project information</summary><p>Current focus: reliability and clearer workflows.</p><p class="meta">Roadmap, context, rules and validation stay in Project details.</p>{btn('Project details')}</details>
        </section></div>'''
    lesson_actions = btn('Resume', True, 'Resume this saved lesson through the existing draft-save barrier.') + btn('Schedule…', note='Open the existing lesson block editor for the current day; nothing is scheduled until Save.')
    suggestion = f'<article class="next-action-card"><div class="next-action-card__content"><h3>Stop a worker when its caller leaves</h3><p class="next-action-card__meta">Go · 12 min · In progress</p></div><div class="actions">{lesson_actions}</div></article>'
    suggestion += '<article class="next-action-card"><div class="next-action-card__content"><h3>Design table-driven tests for boundary cases</h3><p class="next-action-card__meta">Go · 15 min · Available</p></div><div class="actions">' + btn('Open', note='Open this suggested lesson through the existing guarded route.') + btn('Schedule…') + '</div></article>'
    schedule = '<section><div class="section-header"><h2>Schedule</h2>'+btn('Add block')+'</div><div class="app-list-row"><strong>09:30–09:45</strong><span>Go practice</span></div><div class="app-list-row"><strong>14:00–14:30</strong><span>Implementation review</span></div></section>'
    tasks = '<section><div class="section-header"><h2>Tasks</h2>'+btn('Add task')+'</div><div class="app-list-row"><div class="app-list-row__content">Review retry behavior<br><small>Due today</small></div>'+btn('Complete')+'</div><div class="app-list-row"><div class="app-list-row__content">Write release notes</div>'+btn('Complete')+'</div></section>'
    study = '<section class="section"><div class="section-header"><h2>Practice</h2>'+link('Learning →',fname(option,'learning',stress))+'</div>'+suggestion+'</section>'
    project = '<section class="section section-border"><div class="route-row"><h2>Project work</h2>'+link('Next features →',fname(option,'projects',stress))+'</div></section>'
    if option == 'b':
        study = '<div class="layout-two"><section class="preview section"><div class="section-header"><h2>Practice</h2>'+link('Learning →',fname(option,'learning',stress))+'</div>'+suggestion+'</section><section class="preview section"><h2>Project work</h2><p class="meta">Continue in your project workspace.</p>'+link('Next features →',fname(option,'projects',stress),True)+'</section></div>'
        project = ''
    return heading('Today','Thursday, 1 October',btn('Previous day')+btn('Next day'))+offline+study+project+'<div class="layout-two section-border">'+schedule+tasks+'</div>'

JS = r'''
const catalog=CATALOG, topics=TOPICS, features=FEATURES;
const option=OPTION, page=PAGE;
let topic='go', selected=0;
const esc = value => String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const button = (name,primary=false,note=name) => `<button class="btn ${primary?'btn--primary':''}" data-note="${esc(note)}">${name}</button>`;
function learning(){
 if(page!=='learning')return;
 const rows=catalog[topic];
 document.querySelector('#topic-title').textContent=topics.find(t=>t.id===topic).name;
 document.querySelectorAll('[data-topic]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.topic===topic)));
 const details=(l)=>`<p>${esc(l.objective)}</p><p class="meta">${esc(l.difficulty)} · ${esc(l.format)}</p>`;
 const action=(l)=>button(l.started?'Resume':'Open',true,'Existing guarded lesson entry; this preview creates no attempt.');
 let markup='';
 if(option==='a')markup=rows.map(l=>`<article class="next-action-card"><div class="next-action-card__content"><h3>${esc(l.title)}</h3><p class="next-action-card__meta">${l.minutes} min${l.started?' · In progress':''}</p><details><summary>Details &amp; options</summary>${details(l)}${button('Show another',false,'Keep the existing confirmation: replacing this assignment does not complete it; unfinished work stays in History.')}</details></div><div class="actions">${action(l)}</div></article>`).join('');
 else {let l=rows[selected];markup=`<div class="layout-two"><div>${rows.map((x,i)=>`<button class="btn list-button" data-lesson="${i}" aria-pressed="${i===selected}"><span>${esc(x.title)}<br><small>${x.minutes} min${x.started?' · In progress':''}</small></span></button>`).join('')}</div><article class="preview"><h2>${esc(l.title)}</h2>${details(l)}<div class="actions">${action(l)}</div><details><summary>More options</summary>${button('Show another',false,'Keep the existing assignment-dismissal confirmation and save guard.')}</details></article></div>`;}
 document.querySelector('#learning-items').innerHTML=markup;
}
function project(index=0){
 if(page!=='projects'||option!=='b'||!document.querySelector('#feature-preview'))return;
 const f=features[index];
 document.querySelectorAll('[data-feature]').forEach(b=>b.setAttribute('aria-pressed',String(Number(b.dataset.feature)===index)));
 document.querySelector('#feature-preview').innerHTML=`<p class="meta">Ready · ${esc(f.meta)}</p><h2>${esc(f.title)}</h2><p>${esc(f.objective)}</p><div class="actions">${button('View feature',true,'Open existing feature details.')}${button('Mark complete',false,'Explicit file mutation: preserve current verification, conflicts and Undo.')}</div>`;
}
document.addEventListener('click',e=>{
 const t=e.target.closest('[data-topic]'); if(t){topic=t.dataset.topic;selected=0;learning();return;}
 const l=e.target.closest('[data-lesson]'); if(l){selected=Number(l.dataset.lesson);learning();return;}
 const f=e.target.closest('[data-feature]');if(f){project(Number(f.dataset.feature));return;}
 const b=e.target.closest('[data-note]');if(b){document.querySelector('#demo-title').textContent=b.textContent;document.querySelector('#demo-copy').textContent=b.dataset.note;document.querySelector('#demo').showModal();}
});
const activity=document.querySelector('#activity-type');
if(activity)activity.addEventListener('change',()=>{document.querySelector('#task-link').hidden=activity.value!=='task';document.querySelector('#lesson-link').hidden=activity.value!=='lesson';});
const state=document.querySelector('#state');
state.addEventListener('change',()=>{
 document.querySelector('#error').hidden=state.value!=='error';
 document.querySelector('#empty').hidden=state.value!=='empty';
 document.querySelector('#surface').hidden=state.value!=='ready';
});
document.querySelector('#large').addEventListener('change',e=>document.body.classList.toggle('large',e.target.checked));
learning();project();
'''


def page_html(option,page,stress=False):
    label = 'A · Direct actions' if option=='a' else 'B · Browse then act'
    nav=''
    for name in ['Today','Learning','Projects','Focus','Tasks','News','Settings']:
        slug=name.lower()
        current = ' aria-current="page"' if slug == page else ''
        nav += f'<a href="{fname(option,slug,stress)}"{current}>{name}</a>' if option == 'b' or slug in ['today','learning','projects'] else f'<span title="Not included in this exploration">{name}</span>'
    comparison = f'<a href="{fname("b" if option=="a" else "a",page,stress)}">Other option</a>' if page in ['today','learning','projects'] else ''
    script=JS.replace('CATALOG',json.dumps(data)).replace('TOPICS',json.dumps(topics)).replace('FEATURES',json.dumps(features)).replace('OPTION',json.dumps(option)).replace('PAGE',json.dumps(page))
    error={'learning':('Lessons unavailable','Retry catalog'), 'projects':('Project unavailable','Refresh'), 'today':('Today could not load','Retry'), 'tasks':('Tasks unavailable','Retry'), 'focus':('Session status unavailable','Retry'), 'news':('Saved headlines unavailable','Retry'), 'settings':('Preferences unavailable','Retry')}[page]
    empty={'learning':'No choices in this topic. Try another topic or generate a lesson.', 'projects':'No ready features. View project details for blockers.', 'today':'Nothing planned for this day. Add a task or a block.', 'tasks':'No tasks for this filter. Add a task.', 'focus':'No sessions yet. Start from Focus when ready.', 'news':'No saved headlines yet. Refresh your selected feeds.', 'settings':'No project folders connected. Add a folder in Project folders.'}[page]
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{label} — {page.title()}</title><link rel="stylesheet" href="../../design-system/tokens.css"><link rel="stylesheet" href="../../design-system/components.css"><style>{CSS}</style></head>
<body class="{'large' if stress else ''}"><!-- {'Selected B design direction: browse then act in Learning/Projects; main screens only; first eligible item previews without mutation. Supporting screen rules confirmed by user.' if option == 'b' else 'Alternative A considered but not selected.'} Design selection is not implementation approval. Not a rendered native screenshot. All records/progress illustrative. -->
<header class="mock-meta"><strong>{label}</strong><span>HTML design reference · illustrative data · no app mutations</span><a href="index.html">Compare options</a>{comparison}</header>
<nav class="global" aria-label="Destinations">{nav}</nav>
<div class="state-tools"><label>Preview state <select id="state"><option value="ready">{'Offline / enlarged' if stress else 'Populated'}</option><option value="empty">Empty</option><option value="error">Read failure</option></select></label><label><input id="large" type="checkbox" {'checked' if stress else ''}> Large text</label><span>{'All seven destinations linked.' if option == 'b' else 'Only Today, Learning and Projects are linked.'}</span></div>
<main><div id="surface">{content(option,page,stress)}</div><section id="error" hidden><h1>{page.title()}</h1><div class="error-banner"><div><strong>{error[0]}</strong><p>Saved work is retained.</p></div>{btn(error[1])}</div></section><section id="empty" hidden><h1>{page.title()}</h1><div class="empty-state"><p>{empty}</p></div></section></main>
<dialog id="demo" aria-labelledby="demo-title"><p class="meta">Preview boundary — not a simulated success</p><h2 id="demo-title"></h2><p id="demo-copy"></p><form method="dialog"><button class="btn">Close</button></form></dialog>
<script>{script}</script></body></html>'''

for option in ['a','b']:
    for page in (['today','learning','projects','tasks','focus','news','settings'] if option == 'b' else ['today','learning','projects']):
        for stress in [False,True]:
            (ROOT/fname(option,page,stress)).write_text(page_html(option,page,stress))

cards=''
for option,title,description in [
    ('a','A — Direct actions','Considered, not selected. Keep the next action beside each item. Fewer selection states and closest to the current implementation.'),
    ('b','B — Browse then act · SELECTED','Selected for Learning and Projects. Separate choosing from acting with a list and preview; apply lighter cleanup to the other destinations.')]:
    cards+=f'<section class="index-card"><h2>{title}</h2><p>{description}</p><p class="meta">Today ↔ Learning ↔ Projects · peer destinations, not a wizard</p><ul>'
    for page in (['today','learning','projects','tasks','focus','news','settings'] if option == 'b' else ['today','learning','projects']):
        cards+=f'<li><a href="{fname(option,page)}">{page.title()}</a> · <a href="{fname(option,page,True)}">offline / enlarged mirror</a></li>'
    cards+=f'</ul><iframe title="{title}: Learning preview" src="{fname(option,"learning")}"></iframe></section>'
index=f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Kontrol — hierarchy alternatives</title><link rel="stylesheet" href="../../design-system/tokens.css"><link rel="stylesheet" href="../../design-system/components.css"><style>{CSS}</style></head><body><main>
<h1>Less explanation. Clearer next steps.</h1><p>Two alternatives using the existing Kontrol theme and destinations.</p><p class="meta">Planning artifact · B selected as design direction, not implementation approval · no native app capture or visual verification claimed.</p>
<div class="index-grid">{cards}</div><section class="section-border"><h2>What stays separate</h2><p>Today supports practice and planning. Learning owns practice, History and Coverage. Projects owns feature selection and explicit file completion. Focus tracks time, not task or lesson completion. Settings owns configuration.</p><h2>Boundaries of these previews</h2><p>Topic and item selection, disclosure, page links and preview-state controls are interactive. Other actions explain the existing destination/operation without performing it. The four example lessons are taken from the bundled catalog, not persisted user slots; progress, project content, tasks and schedule are illustrative.</p><p>No new ranking, account, network request, completion policy or data model is proposed. Project work on Today is only a link. Offline/enlarged variants show local lessons and stale project handling; they are design proposals, not test evidence.</p></section></main></body></html>'''
(ROOT/'index.html').write_text(index)
print('Generated 20 preview pages and index under',ROOT)
