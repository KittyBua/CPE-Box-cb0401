'use strict';
// System (health, lights, reboot, access, SSH, password, firmware) and
// Console (raw commands).

Views.system = { sources: ['health', 'leds', 'info', 'ssh', 'rname'] };

on('rname', d => {
  if (d && document.activeElement !== $('#routerName')) $('#routerName').value = d.name || '';
});
$('#nameForm').addEventListener('submit', e => {
  e.preventDefault();
  const name = $('#routerName').value.trim();
  if (!/^[\w .-]{1,32}$/.test(name)) return toast('Letters, digits, spaces, dots, dashes and underscores only', 'err');
  withBusy($('button', e.target), async () => {
    await stock('name_set', { name, locale: Sources.rname.data?.locale || 'Home' }, ['rname']);
    toast('Router renamed');
  }).catch(() => {});
});
Views.console = { sources: [], show() { $('#cmd').focus(); } };

on('health', h => {
  if (!h) return;
  $('#sysGauges').innerHTML = healthGauges(h);
  setText('sysUptime', h.uptime_sec != null ? 'up ' + fmtUptime(h.uptime_sec) : '');
  $('#sysKv').innerHTML = kvRows([
    ['Load (1 / 5 / 15 min)', h.load1 != null ? `${h.load1} / ${h.load5} / ${h.load15}` : ''],
    ['Memory available', h.mem_free_real_kb != null ? Math.round(h.mem_free_real_kb / 1024) + ' MB' : ''],
    ['Uptime', h.uptime_sec != null ? fmtUptime(h.uptime_sec) : ''],
    ['Model', [Sources.info.data?.model, Sources.info.data?.firmware && 'firmware ' + Sources.info.data.firmware].filter(Boolean).join(' · ')],
    ['CPE Box', Sources.info.data ? 'v' + Sources.info.data.version : ''],
  ]);
});

bindLedSwitch($('#sysLeds'));
on('info', i => { if (i) renderAccess($('#sysAccess'), i, 'sysAcc'); });
on('ssh', s => {
  if (!s) return;
  setText('sshKey', s.cmd_key);
  setText('sshPw', s.cmd_pw);
  setText('sshHost', s.host);
});

$('#rebootBtn').addEventListener('click', e => {
  if (!confirm('Reboot the router?\n\nInternet and Wi-Fi drop for everyone for 1–2 minutes.')) return;
  withBusy(e.currentTarget, async () => {
    await api('/api/reboot', {});
    setMsg('rebootMsg', 'Rebooting. This page reconnects by itself when the router is back.', 'ok');
    waitForRouter();
  }).catch(() => {});
});

// Poll until the router answers again, then reload everything.
function waitForRouter() {
  const started = Date.now();
  const tick = async () => {
    if (Date.now() - started < 40000) return setTimeout(tick, 5000);
    try {
      await api('/api/system-health');
      setMsg('rebootMsg', 'The router is back.', 'ok');
      toast('Router is back online');
      Object.keys(Sources).forEach(k => { Sources[k].at = 0; });
      Hooks.poll && Hooks.poll();
    } catch (e) {
      if (Date.now() - started > 300000) return setMsg('rebootMsg', "The router hasn't come back after 5 minutes - check its lights and cables.", 'err');
      setTimeout(tick, 5000);
    }
  };
  setTimeout(tick, 5000);
}

$('#pwBtn').addEventListener('click', e => {
  const password = $('#newPw').value;
  if (password.length < 4) return setMsg('pwMsg', 'At least 4 characters', 'err');
  if (!confirm("Change the router's root password?\n\nEvery phone or laptop signed in to this panel will have to sign in again with the new one. Keep it somewhere safe - without it the only way back is a factory reset.")) return;
  withBusy(e.currentTarget, async () => {
    await api('/api/root-password', { password });
    $('#newPw').value = '';
    setMsg('pwMsg', 'Changed', 'ok');
    toast('Root password changed');
  }).catch(err => setMsg('pwMsg', err.message, 'err'));
});

$('#spoofBtn').addEventListener('click', e => {
  if (!confirm('Make the router report firmware version 0.0.1 until the next reboot?\n\nThis only lifts the stock updater\'s downgrade block. Nothing is written to flash.')) return;
  withBusy(e.currentTarget, async () => {
    const d = await api('/api/spoof-version', {});
    setMsg('spoofMsg', 'Router now reports: ' + (d.reported || '0.0.1'), 'ok');
  }).catch(err => setMsg('spoofMsg', err.message, 'err'));
});

// --------------------------------------------------------------- console ---

async function runConsole(btn, fn, label) {
  const out = $('#out');
  setMsg('runMsg', 'Running…');
  const t0 = performance.now();
  try {
    await withBusy(btn, async () => {
      const d = await fn();
      out.textContent = d.output || '(no output)';
      setMsg('runMsg', `${label} · ${((performance.now() - t0) / 1000).toFixed(1)} s`, 'ok');
    });
  } catch (err) {
    out.textContent = err.message;
    setMsg('runMsg', 'Failed', 'err');
  }
}
$('#runBtn').addEventListener('click', e => {
  const cmd = $('#cmd').value.trim();
  if (!cmd) return $('#cmd').focus();
  runConsole(e.currentTarget, () => api('/api/raw', { cmd }), 'Done');
});
$('#uciBtn').addEventListener('click', e => runConsole(e.currentTarget, () => api('/api/uci-dump'), 'UCI dump'));
$('#clearBtn').addEventListener('click', () => { $('#out').textContent = ''; setMsg('runMsg', ''); });
$('#cmd').addEventListener('keydown', e => {
  if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); $('#runBtn').click(); }
});

// -------------------------------------------------------------- AT modem ---

// Clean up microcom output for the terminal panel: strip the modem's own
// echo of the command back at us and the CR characters that make everything
// look double-spaced in the panel's pre.
function cleanAT(text, sent) {
  if (!text) return '';
  let s = text.replace(/\r\n/g, '\n').replace(/\r/g, '');
  if (sent) {
    const echoed = s.indexOf(sent);
    if (echoed >= 0 && echoed < 3) s = s.slice(echoed + sent.length);
  }
  return s.replace(/^\n+/, '').replace(/\n{3,}/g, '\n\n').trimEnd();
}

async function runAT(btn, cmd) {
  const out = $('#atOut');
  if (!cmd) return $('#atCmd').focus();
  setMsg('atMsg', 'Sending…');
  const t0 = performance.now();
  try {
    await withBusy(btn, async () => {
      const d = await api('/api/at', { cmd });
      out.textContent = cleanAT(d.output, cmd) || '(no reply)';
      setMsg('atMsg', `Done · ${((performance.now() - t0) / 1000).toFixed(1)} s`, 'ok');
    });
  } catch (err) {
    out.textContent = err.message;
    setMsg('atMsg', 'Failed', 'err');
  }
}

$('#atRunBtn').addEventListener('click', e => runAT(e.currentTarget, $('#atCmd').value.trim()));
$('#atClearBtn').addEventListener('click', () => { $('#atOut').textContent = ''; setMsg('atMsg', ''); });
$('#atCmd').addEventListener('keydown', e => {
  if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); $('#atRunBtn').click(); }
});
// Preset buttons: fill the input and fire.
$$('#v-console [data-at]').forEach(b => b.addEventListener('click', e => {
  const cmd = e.currentTarget.dataset.at;
  $('#atCmd').value = cmd;
  runAT($('#atRunBtn'), cmd);
}));

// ----------------------------------------------------------------- IMEI ---

async function readIMEI(btn) {
  try {
    await withBusy(btn, async () => {
      const d = await api('/api/at', { cmd: 'AT+CGSN' });
      const m = cleanAT(d.output, 'AT+CGSN').match(/\b(\d{15})\b/);
      setText('imeiCurrent', m ? m[1] : '—');
    });
  } catch (err) {
    setText('imeiCurrent', '—');
    setMsg('imeiMsg', err.message, 'err');
  }
}
$('#imeiCheckBtn').addEventListener('click', e => readIMEI(e.currentTarget));
$('#imeiApplyBtn').addEventListener('click', async e => {
  const imei = ($('#imeiNew').value || '').trim();
  if (!/^\d{15}$/.test(imei)) return setMsg('imeiMsg', 'IMEI is 15 digits', 'err');
  if (!confirm(`Write ${imei} as the modem's IMEI?\n\nThis is permanent from the modem's side - it does not revert on a reboot or reset, only by writing another IMEI back in.\n\nThe cellular connection will drop for a few seconds while the modem re-registers.`)) return;
  try {
    await withBusy(e.currentTarget, async () => {
      const d = await api('/api/at', { cmd: `AT+EGMR=1,7,"${imei}"` });
      const reply = cleanAT(d.output, `AT+EGMR=1,7,"${imei}"`);
      if (!/\bOK\b/.test(reply)) throw new Error(reply.trim() || 'Modem rejected the command');
      // Reset the modem's radio so it re-registers with the new identity.
      await api('/api/at', { cmd: 'AT+CFUN=1,1' });
      setMsg('imeiMsg', 'Written · modem is re-registering', 'ok');
      $('#imeiNew').value = '';
      setTimeout(() => readIMEI($('#imeiCheckBtn')), 8000);
    });
  } catch (err) {
    setMsg('imeiMsg', err.message, 'err');
  }
});
// Read current IMEI when the Cellular tab first opens.
window.addEventListener('hashchange', () => {
  if (location.hash === '#cellular' && $('#imeiCurrent').textContent === '—') readIMEI($('#imeiCheckBtn'));
});
if (location.hash === '#cellular') setTimeout(() => readIMEI($('#imeiCheckBtn')), 500);
