'use strict';
// Boot: header, polling and routing. Loaded last.

const ALWAYS = ['cellular', 'info', 'sms']; // the header and tab badges need these on every page

// --------------------------------------------------------------- header ---

on('cellular', c => {
  if (!c) return;
  const h = headlineSignal(c);
  const q = h && quality('rsrp', h.v);
  setBars($('#liveBars'), q ? q.level : 0, !c.registered ? 'q-poor' : q ? q.cls : '');
  setText('liveOp', c.operator || (c.registered ? 'Connected' : 'No service'));
  setText('liveRat', c.network_type || '—');
});

on('info', i => {
  if (!i) return;
  $('#model').textContent = ['Xiaomi 5G CPE Pro', i.model, i.firmware ? 'firmware ' + i.firmware : ''].filter(Boolean).join(' · ');
  $('#model').title = 'CPE Box v' + i.version;
  setText('appver', i.version ? 'v' + i.version : '');
  $('#logoutBtn').hidden = !!i.local;
});

// A banner when the router itself can't be reached (the panel is fine but
// SSH to the router fails), cleared by the next successful read.
Hooks.afterRefresh = () => {
  const errs = Object.values(Sources).filter(s => s.error && s.at);
  const oks = Object.values(Sources).filter(s => !s.error && s.at);
  const latestErr = errs.sort((a, b) => b.at - a.at)[0];
  const latestOk = oks.sort((a, b) => b.at - a.at)[0];
  const down = latestErr && (!latestOk || latestErr.at > latestOk.at);
  $('#connBanner').hidden = !down;
  if (down) setText('connBannerText', latestErr.error.message);
  if (latestOk) $('#refreshBtn').title = 'Refresh now - updated ' + new Date(latestOk.at).toLocaleTimeString();
};

// -------------------------------------------------------------- polling ---

function neededSources() {
  return new Set([...ALWAYS, ...((Views[currentView] || {}).sources || [])]);
}

// mode: none = timer tick (skipped while the tab is hidden), 'show' = fetch
// whatever is stale even in a background tab, 'all' = refetch everything.
function poll(mode) {
  if (document.hidden && !mode) return;
  const force = mode === 'all';
  const now = Date.now();
  const jobs = [];
  for (const name of neededSources()) {
    const s = Sources[name];
    if (force || !s.at || now - s.at >= s.every) jobs.push(refresh(name));
  }
  return Promise.all(jobs);
}
Hooks.poll = () => poll('all');

$('#refreshBtn').addEventListener('click', async e => {
  const b = e.currentTarget;
  b.classList.add('spin');
  await poll('all');
  b.classList.remove('spin');
});
setInterval(() => poll(), 5000);
document.addEventListener('visibilitychange', () => { if (!document.hidden) poll(); });

// ------------------------------------------------------------------ boot ---

paintThemeButton();
$('#themeBtn').addEventListener('click', toggleTheme);

window.addEventListener('hashchange', () => { showView(location.hash.slice(1)); poll('show'); });
showView(location.hash.slice(1) || 'overview');
poll('show');
