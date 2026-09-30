'use strict';
// Network: LAN address, DHCP, address reservations, port forwarding, UPnP
// and DMZ - all through the stock actions.

Views.network = { sources: ['lan', 'dhcp', 'hosts', 'portfwd', 'upnp', 'dmz'] };

const ipRe = /^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$/;
const lanPrefix = () => (Sources.lan.data?.info?.ipv4?.[0]?.ip || '192.168.31.1').split('.').slice(0, 3).join('.');

// ------------------------------------------------------------- LAN / DHCP ---

on('lan', d => {
  const v4 = d?.info?.ipv4?.[0];
  if (!v4) return;
  const f = $('#lanForm');
  if (document.activeElement?.form !== f) { f.ip.value = v4.ip; f.mask.value = v4.mask; }
});

$('#lanForm').addEventListener('submit', e => {
  e.preventDefault();
  const f = e.target, ip = f.ip.value.trim();
  if (!ipRe.test(ip)) return toast("That isn't an IPv4 address", 'err');
  if (!/^(192\.168|10\.|172\.(1[6-9]|2\d|3[01]))/.test(ip)) return toast('Use a private address (192.168.x.1, 10.x.x.1 or 172.16-31.x.1)', 'err');
  if (!confirm(`Change the router's address to ${ip}?\n\nThe router restarts and every device gets a new address. Open the panel at http://cpe.box (or http://${ip.split('.').slice(0, 3).join('.')}.x:7777 on this computer) afterwards. If you run CPE Box on this computer, put ROUTER_IP=${ip} in panel/.env.`)) return;
  withBusy($('button', f), async () => {
    await stock('lan_ip', { ip, mask: f.mask.value });
    toast('Router address changed - it is restarting');
  }).catch(() => {});
});

on('dhcp', d => {
  const i = d?.info;
  if (!i) return;
  const f = $('#dhcpForm');
  if (f.dataset.dirty) return;
  f.on.checked = i.ignore !== '1';
  const start = Number(i.start), limit = Number(i.limit);
  f.start.value = start;
  f.end.value = Math.min(254, start + limit - 1);
  // stock lease time is like "12h" or "720m"
  const m = /^(\d+)([hm]?)$/.exec(i.leasetime || '');
  f.lease.value = m ? (m[2] === 'm' ? Math.max(1, Math.round(m[1] / 60)) : m[1]) : 12;
});
$('#dhcpForm').addEventListener('input', e => { e.currentTarget.dataset.dirty = '1'; setMsg('dhcpMsg', 'Unsaved changes'); });
$('#dhcpForm').addEventListener('submit', e => {
  e.preventDefault();
  const f = e.target, start = Number(f.start.value), end = Number(f.end.value);
  if (!(start >= 2 && end <= 254 && end >= start)) return setMsg('dhcpMsg', 'First must be 2 or more, last 254 or less, and first ≤ last', 'err');
  if (!f.on.checked && !confirm('Turn the DHCP server off? New devices will only connect if you set their addresses by hand.')) return;
  const dhcp = Sources.dhcp.data?.info || {};
  withBusy($('button', f), async () => {
    await stock('dhcp_set', {
      start, end, limit: end - start + 1, leasetime: (Number(f.lease.value) || 12) * 60 + 'm',
      ignore: f.on.checked ? 0 : 1, router: dhcp.router || '', dns1: dhcp.dns1 || '', dns2: dhcp.dns2 || '',
    }, ['dhcp']);
    delete f.dataset.dirty;
    setMsg('dhcpMsg', 'Saved', 'ok');
    toast('DHCP saved');
  }).catch(err => setMsg('dhcpMsg', err.message, 'err'));
});

// ---------------------------------------------------------- reservations ---

on('hosts', d => {
  if (!d) return;
  const list = arr(d.list);
  $('#bindList').innerHTML = list.length ? list.map(b => `<div class="dev">
      <div class="avatar online">${icon('link')}</div>
      <div class="main" style="cursor:default"><div class="name">${esc(b.name || b.mac)}</div><div class="meta">${esc(b.ip)} · ${esc(String(b.mac).toUpperCase())}</div></div>
      <button class="ghost small" data-unbind="${esc(b.mac)}" aria-label="Remove">${icon('trash')}</button></div>`).join('')
    : '<div class="empty">No reservations yet.</div>';
});
$('#bindList').addEventListener('click', e => {
  const b = e.target.closest('[data-unbind]');
  if (!b || !confirm('Remove this address reservation?')) return;
  withBusy(b, async () => { await stock('unbind', { mac: b.dataset.unbind }, ['hosts']); toast('Reservation removed'); }).catch(() => {});
});

// ------------------------------------------------------- port forwarding ---

// the list reports "TCP"/"UDP"/..., adding and deleting take 1/2/3
const protoNum = p => /tcp/i.test(p) && /udp/i.test(p) ? 3 : /udp/i.test(p) ? 2 : /tcp/i.test(p) ? 1 : Number(p) || 3;
const PROTO = { 1: 'TCP', 2: 'UDP', 3: 'TCP + UDP' };
on('portfwd', d => {
  if (!d) return;
  const list = arr(d.list);
  $('#pfList').innerHTML = list.length ? list.map((r, i) => `<div class="dev">
      <div class="avatar"><b style="font-size:11px">${esc(r.export)}</b></div>
      <div class="main" style="cursor:default"><div class="name">${esc(r.name)}</div>
        <div class="meta">${PROTO[protoNum(r.protocol)]} · port ${esc(r.export)} → ${esc(r.ip)}:${esc(r.inport)}</div></div>
      <button class="ghost small" data-pf-del="${i}" aria-label="Delete">${icon('trash')}</button></div>`).join('')
    : '<div class="empty">No rules.</div>';
});
$('#pfAddBtn').addEventListener('click', () => {
  const f = $('#pfForm');
  f.hidden = false;
  f.reset();
  f.ip.value = lanPrefix() + '.';
  f.name.focus();
});
$('#pfCancel').addEventListener('click', () => { $('#pfForm').hidden = true; });
$('#pfForm').addEventListener('submit', e => {
  e.preventDefault();
  const f = e.target;
  if (!ipRe.test(f.ip.value.trim())) return toast("The device address isn't valid", 'err');
  withBusy($('button[type=submit]', f), async () => {
    await stock('portfwd_add', { name: f.name.value.trim(), protocol: f.protocol.value, export: f.export.value, inport: f.inport.value, ip: f.ip.value.trim() }, ['portfwd']);
    f.hidden = true;
    toast('Port forwarding rule added');
  }).catch(() => {});
});
$('#pfList').addEventListener('click', e => {
  const b = e.target.closest('[data-pf-del]');
  if (!b) return;
  const r = arr(Sources.portfwd.data?.list)[Number(b.dataset.pfDel)];
  if (!r || !confirm(`Delete the rule "${r.name}"?`)) return;
  withBusy(b, async () => {
    // del_vs_rules matches the rule by the exact fields get_vs_rules returned,
    // so echo protocol back verbatim (it comes as "TCP"/"UDP"/"TCP + UDP"). The
    // stock UI does the same; sending the numeric form here matched nothing, so
    // the daemon reported success but left the rule in place.
    await stock('portfwd_del', {
      name: r.name, service: r.service || '', protocol: r.protocol, export: r.export, inport: r.inport, ip: r.ip,
    }, ['portfwd']);
    toast('Rule deleted');
  }).catch(() => {});
});

// ------------------------------------------------------------ UPnP / DMZ ---

on('upnp', d => {
  if (!d) return;
  $('#upnpOn').checked = String(d.status) === '1';
  $('#upnpOn').disabled = false;
  const list = arr(d.list);
  $('#upnpList').innerHTML = list.map(u => `<div class="kv"><span class="k">${esc(u.name || u.proto || '')}</span>
    <span class="v">${esc(u.eport || '')} → ${esc(u.iaddr || u.ip || '')}:${esc(u.iport || '')}</span></div>`).join('');
});
$('#upnpOn').addEventListener('change', async e => {
  const want = e.target.checked;
  e.target.disabled = true;
  try {
    await stock('upnp_set', { switch: want ? 1 : 0 }, ['upnp']);
    toast(`UPnP ${want ? 'on' : 'off'}`);
  } catch (err) {
    toast(err.message, 'err');
    e.target.checked = !want;
  } finally {
    e.target.disabled = false;
  }
});

on('dmz', d => {
  if (!d) return;
  const on = String(d.status) === '1';
  $('#dmzOn').checked = on;
  $('#dmzOn').disabled = false;
  $('#dmzIpRow').hidden = !on;
  if (on && d.ip && document.activeElement !== $('#dmzIp')) $('#dmzIp').value = d.ip;
});
$('#dmzOn').addEventListener('change', async e => {
  if (e.target.checked) {
    $('#dmzIpRow').hidden = false;
    $('#dmzIp').value = $('#dmzIp').value || lanPrefix() + '.';
    $('#dmzIp').focus();
    return;
  }
  e.target.disabled = true;
  try {
    await stock('dmz_off', { mode: 0 }, ['dmz']);
    $('#dmzIpRow').hidden = true;
    toast('DMZ off');
  } catch (err) {
    toast(err.message, 'err');
    e.target.checked = true;
  } finally {
    e.target.disabled = false;
  }
});
$('#dmzSave').addEventListener('click', e => {
  e.preventDefault();
  const ip = $('#dmzIp').value.trim();
  if (!ipRe.test(ip)) return toast("That isn't a valid address", 'err');
  const host = arr(Sources.hosts.data?.devicelist).find(h => h.ip === ip);
  withBusy(e.currentTarget, async () => {
    await stock('dmz_set', { ip, mac: host?.mac || '', mode: 0 }, ['dmz']);
    toast(`DMZ → ${ip}`);
  }).catch(() => {});
});
