'use strict';
// Devices: who is on the network, which ones are trusted (no alert when
// they join), and where alerts go.

Views.devices = { sources: ['devices', 'hosts'] };

const Dev = { list: [], trusted: new Set(), edit: null, open: null };

// The stock device list: names you gave devices, internet access, speeds
// and address reservations, keyed by MAC.
function hostInfo(mac) {
  const d = Sources.hosts.data;
  if (!d) return {};
  const m = String(mac).toUpperCase();
  return {
    host: arr(d.devicelist).find(h => String(h.mac).toUpperCase() === m),
    bind: arr(d.list).find(b => String(b.mac).toUpperCase() === m),
  };
}
function fmtRate(b) { return b > 0 ? fmtBytes(b) + '/s' : ''; }

function deviceName(d) {
  const h = hostInfo(d.mac).host;
  return (h && h.name && h.name !== h.origin_name ? h.name : '') || d.hostname || d.mdns_name || (h && h.name) || d.vendor || 'Unknown device';
}
function deviceIcon(d) {
  const s = `${d.hostname || ''} ${d.mdns_name || ''}`.toLowerCase();
  if (/iphone|android|phone|pixel|galaxy|redmi/.test(s)) return 'phone';
  if (/macbook|laptop|desktop|pc|imac|windows/.test(s)) return 'laptop';
  return 'devices';
}

function renderDevices() {
  const trusted = Dev.edit || Dev.trusted;
  const q = $('#devFilter').value.trim().toLowerCase();
  const show = $('#devShow').value;
  const rows = Dev.list.filter(d => {
    if (show === 'online' && !d.online) return false;
    if (show === 'offline' && d.online) return false;
    if (show === 'untrusted' && trusted.has(d.mac)) return false;
    if (!q) return true;
    return [d.hostname, d.mdns_name, d.vendor, d.ip, d.mac].some(v => v && v.toLowerCase().includes(q));
  });
  // Online first, then offline; stable within each group so hostname/vendor
  // order from the DHCP-lease side stays predictable.
  rows.sort((a, b) => (b.online ? 1 : 0) - (a.online ? 1 : 0));
  const online = Dev.list.filter(d => d.online).length;
  setText('devCountOn', `${online} online`);
  setText('devCountOff', `${Dev.list.length - online} offline`);
  $('#devCountOn').classList.toggle('active', show === 'online');
  $('#devCountOff').classList.toggle('active', show === 'offline');
  if (!rows.length) {
    $('#devList').innerHTML = `<div class="empty">${Dev.list.length ? 'Nothing matches.' : 'No devices yet.'}</div>`;
    return;
  }
  // Names come from the devices themselves (DHCP / mDNS): always escaped.
  $('#devList').innerHTML = rows.map(d => {
    const name = deviceName(d);
    const { host, bind } = hostInfo(d.mac);
    const blocked = host && host.authority && String(host.authority.wan) === '0';
    const via = !d.hostname && d.mdns_name ? ' <span class="faint">(mDNS)</span>' : '';
    const meta = [d.vendor && name !== d.vendor ? d.vendor : '', d.online ? d.ip : 'offline', d.mac].filter(Boolean).map(esc).join(' · ');
    const st = host && host.statistics;
    const speed = st && d.online ? [fmtRate(Number(st.downspeed)) && '↓ ' + fmtRate(Number(st.downspeed)), fmtRate(Number(st.upspeed)) && '↑ ' + fmtRate(Number(st.upspeed))].filter(Boolean).join('  ') : '';
    const t = trusted.has(d.mac);
    const open = Dev.open === d.mac;
    return `<div class="dev ${open ? 'open' : ''}">
      <div class="avatar ${blocked ? 'alert' : d.online ? (t ? 'online' : 'alert') : ''}">${icon(blocked ? 'lock' : deviceIcon(d))}</div>
      <div class="main" data-open="${esc(d.mac)}" tabindex="0" role="button" aria-expanded="${open}"><div class="name">${esc(name)}${via}${blocked ? ' <span class="pill bad" style="padding:1px 8px">No internet</span>' : ''}</div>
        <div class="meta">${meta}</div>${speed ? `<div class="speed">${esc(speed)}</div>` : ''}</div>
      <div class="end"><span class="${t ? '' : 'q-fair'}">${t ? 'Trusted' : d.online ? 'Not trusted' : ''}</span>
        <label class="switch"><input type="checkbox" data-mac="${esc(d.mac)}" ${t ? 'checked' : ''} aria-label="Trust ${esc(name)}"><span></span></label>
      </div></div>
      ${open ? devicePanel(d, host, bind, blocked) : ''}`;
  }).join('');
}

function devicePanel(d, host, bind, blocked) {
  const mac = esc(d.mac);
  return `<div class="dev-panel">
    <label class="field">Name<div class="copy-row"><input type="text" data-name="${mac}" value="${esc(deviceName(d))}" maxlength="32"><button data-rename="${mac}">Rename</button></div></label>
    <div class="toggle-row"><div class="t"><b>Internet access</b><small>Off keeps it on the home network but offline</small></div>
      <label class="switch"><input type="checkbox" data-access="${mac}" ${blocked ? '' : 'checked'} ${host ? '' : 'disabled'}><span></span></label></div>
    <div class="toggle-row"><div class="t"><b>Always the same address</b><small>${bind ? 'Reserved: ' + esc(bind.ip) : 'Reserve its current address in DHCP'}</small></div>
      <label class="switch"><input type="checkbox" data-bind="${mac}" ${bind ? 'checked' : ''} ${bind || d.ip ? '' : 'disabled'}><span></span></label></div>
  </div>`;
}

$('#devList').addEventListener('click', e => {
  const o = e.target.closest('[data-open]');
  if (o) { Dev.open = Dev.open === o.dataset.open ? null : o.dataset.open; renderDevices(); return; }
  const r = e.target.closest('[data-rename]');
  if (r) {
    const mac = r.dataset.rename, name = $(`[data-name="${mac}"]`).value.trim();
    if (!name) return toast('Give it a name', 'err');
    withBusy(r, async () => {
      await stock('rename', { mac, name }, ['hosts']);
      toast('Renamed');
    }).catch(() => {});
  }
});
$('#devList').addEventListener('keydown', e => {
  const o = e.target.closest('[data-open]');
  if (o && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); o.click(); }
});

$('#devList').addEventListener('change', async e => {
  const acc = e.target.dataset.access, bnd = e.target.dataset.bind;
  if (acc || bnd) {
    const want = e.target.checked;
    const d = Dev.list.find(x => x.mac === (acc || bnd));
    e.target.disabled = true;
    try {
      if (acc) {
        if (!want && !confirm(`Cut ${deviceName(d)} off from the internet? It stays on your Wi-Fi.`)) { e.target.checked = true; return; }
        await stock('access', { mac: acc, wan: want ? 1 : 0 }, ['hosts']);
        toast(want ? 'Internet access restored' : 'Internet access blocked');
      } else if (want) {
        await stock('bind', { data: JSON.stringify([{ mac: bnd, ip: d.ip, name: deviceName(d) }]) }, ['hosts']);
        toast(`${d.ip} reserved`);
      } else {
        await stock('unbind', { mac: bnd }, ['hosts']);
        toast('Reservation removed');
      }
    } catch (err) {
      toast(err.message, 'err');
      e.target.checked = !want;
    } finally {
      e.target.disabled = false;
    }
    return;
  }
  const mac = e.target.dataset.mac;
  if (!mac) return;
  if (!Dev.edit) Dev.edit = new Set(Dev.trusted);
  if (e.target.checked) Dev.edit.add(mac); else Dev.edit.delete(mac);
  const changed = Dev.edit.size !== Dev.trusted.size || [...Dev.edit].some(m => !Dev.trusted.has(m));
  $('#devSave').disabled = !changed;
  setMsg('devMsg', changed ? 'Unsaved changes' : '');
  if (!changed) Dev.edit = null;
  renderDevices();
});
$('#devFilter').addEventListener('input', renderDevices);
$('#devShow').addEventListener('change', renderDevices);
$$('.dev-chip').forEach(a => a.addEventListener('click', e => {
  e.preventDefault();
  const s = a.dataset.show;
  const sel = $('#devShow');
  sel.value = sel.value === s ? 'all' : s;
  renderDevices();
}));

$('#devSave').addEventListener('click', e => withBusy(e.currentTarget, async () => {
  const macs = [...(Dev.edit || Dev.trusted)];
  const d = await api('/api/device-monitor/whitelist', { macs });
  Dev.edit = null;
  setMsg('devMsg', '');
  toast('Trusted list saved');
  if (d && d.devices) publish('devices', d); else refresh('devices');
}).catch(() => {}).finally(() => { $('#devSave').disabled = !Dev.edit; }));

on('devices', (data, err) => {
  if (!data) {
    if (err) $('#devList').innerHTML = `<div class="empty">${esc(err.message)}</div>`;
    return;
  }
  Dev.trusted = new Set(data.whitelist || []);
  // online devices, plus trusted ones that are offline right now
  const byMac = {};
  (data.devices || []).forEach(d => { byMac[d.mac] = d; });
  (data.whitelist || []).forEach(mac => { if (!byMac[mac]) byMac[mac] = { mac, ip: null, hostname: null }; });
  Dev.list = Object.values(byMac).sort((a, b) =>
    (!!b.ip - !!a.ip) || deviceName(a).localeCompare(deviceName(b)));
  if (!typingName()) renderDevices();
  renderNotify(data.notify || {});
});
// a background refresh must not wipe a name being typed
const typingName = () => !!document.activeElement?.dataset?.name;
on('hosts', () => { if (Dev.list.length && !typingName()) renderDevices(); });

// ---------------------------------------------------------------- alerts ---

let notifyDirty = false;

function backendChoice() {
  const r = $('#notifySeg input:checked');
  return r ? r.value : 'ntfy';
}
function showBackendFields() {
  const b = backendChoice();
  $('#ntfyFields').hidden = b !== 'ntfy';
  $('#tgFields').hidden = b !== 'telegram';
}
function markNotifyDirty() {
  notifyDirty = true;
  $('#notifySave').disabled = false;
  setMsg('notifyMsg', 'Unsaved changes');
}

function renderNotify(n) {
  if (notifyDirty) return;
  $$('#notifySeg input').forEach(i => { i.checked = i.value === (n.backend || 'ntfy'); });
  setText('ntfyTopic', n.ntfy_topic ? 'ntfy.sh/' + n.ntfy_topic : 'Not set up');
  $('#tgToken').value = n.telegram_bot_token || '';
  $('#tgChat').value = n.telegram_chat_id || '';
  $('#smsFwd').checked = n.sms_forward !== false;
  showBackendFields();
}

$('#notifySeg').addEventListener('change', () => { showBackendFields(); markNotifyDirty(); });
['#tgToken', '#tgChat'].forEach(s => $(s).addEventListener('input', markNotifyDirty));
$('#tgTokenEye')?.addEventListener('click', () => $('#tgToken').classList.toggle('masked'));
$('#smsFwd').addEventListener('change', markNotifyDirty);

$('#notifySave').addEventListener('click', e => withBusy(e.currentTarget, async () => {
  const body = { backend: backendChoice(), sms_forward: $('#smsFwd').checked };
  if (body.backend === 'telegram') {
    body.telegram_bot_token = $('#tgToken').value.trim();
    body.telegram_chat_id = $('#tgChat').value.trim();
    if (!body.telegram_bot_token || !body.telegram_chat_id) throw new Error('Telegram needs both a bot token and a chat ID');
  }
  await api('/api/notify-config', body);
  notifyDirty = false;
  setMsg('notifyMsg', '');
  toast('Alert settings saved');
  refresh('devices');
}).catch(() => {}).finally(() => { $('#notifySave').disabled = !notifyDirty; }));
