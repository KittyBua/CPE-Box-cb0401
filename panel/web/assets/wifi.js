'use strict';
// Wi-Fi: each radio's name, password, security, channel, width, power,
// visibility - saved through the stock set_wifi action, like the Xiaomi
// page does - plus the 2.4 GHz channel scan.

Views.wifi = { sources: ['wifiCfg', 'status'] };

// stock wifiIndex: 1 = 2.4 GHz, 2 = 5 GHz (the order of getAllWifiInfo)
const BANDS = { 1: { label: '2.4 GHz', key: '2.4', ico: 'cyan' }, 2: { label: '5 GHz', key: '5', ico: '' } };
const SECURITY = [['ccmp', 'WPA3'], ['psk2+ccmp', 'WPA2 / WPA3'], ['psk2', 'WPA2'], ['mixed-psk', 'WPA / WPA2'], ['none', 'Open (no password)']];
const POWER = [['max', 'Strong'], ['mid', 'Standard'], ['min', 'Eco']];
const IDLE_MSG = 'Saving restarts this radio - its devices reconnect.';
const wifiDirty = {};
const wifiCur = {};

function bandForm(idx) {
  const b = BANDS[idx];
  return `<div class="card-h"><div class="ico ${b.ico}"><svg class="i"><use href="#i-wifi"/></svg></div><h2>${b.label}</h2>
      <div class="right"><span class="pill" data-f="pill">—</span>
        <label class="switch" title="Turn this radio on or off"><input type="checkbox" data-f="on" aria-label="${b.label} on"><span></span></label></div></div>
    <form data-f="form" autocomplete="off" data-form-type="other">
      <!-- Decoy fields (see below) - browsers key their "save password?"
           heuristic off the presence of a text field followed by a password
           field. We keep the real password field as type="text" with a CSS
           mask (see .masked in app.css) so browsers don't treat it as a
           login credential and don't prompt to save the Wi-Fi key when the
           user tabs away. -->
      <input type="text" name="fakeuser" autocomplete="username" tabindex="-1" aria-hidden="true" style="position:absolute;opacity:0;pointer-events:none;height:0;width:0">
      <input type="password" name="fakepass" autocomplete="new-password" tabindex="-1" aria-hidden="true" style="position:absolute;opacity:0;pointer-events:none;height:0;width:0">
      <label class="field">Network name<input type="text" name="ssid" required autocomplete="off"></label>
      <div class="two" style="margin-top:12px">
        <label class="field">Security<select name="encryption">${SECURITY.map(([v, l]) => `<option value="${v}">${l}</option>`).join('')}</select></label>
        <label class="field" data-f="pwdRow">Password<div class="pwd-wrap"><input type="text" name="wpakey" class="masked" maxlength="63" autocomplete="off" spellcheck="false" data-form-type="other">
          <button type="button" data-f="eye" aria-label="Show password">${icon('eye')}</button></div></label>
        <label class="field">Channel<select name="channel"></select></label>
        <label class="field">Width<select name="bandwidth"></select></label>
        <label class="field">Transmit power<select name="txpwr">${POWER.map(([v, l]) => `<option value="${v}">${l}</option>`).join('')}</select></label>
      </div>
      <div class="toggle-row" style="margin-top:6px"><div class="t"><b>Hide network name</b><small>Devices have to type the name to join</small></div>
        <label class="switch"><input type="checkbox" name="hidden"><span></span></label></div>
      <div class="toggle-row" style="border-top:1px solid var(--border)"><div class="t"><b>Wi-Fi 6</b><small>Turn off only if an old device can't connect</small></div>
        <label class="switch"><input type="checkbox" name="ax"><span></span></label></div>
      <div class="note warn" data-f="drift" hidden style="margin-top:14px"><svg class="i"><use href="#i-info"/></svg><span></span></div>
      <div class="dirty-bar"><span class="msg" data-f="msg">${IDLE_MSG}</span>
        <button class="primary" type="submit" data-f="save" disabled>Save</button></div>
    </form>`;
}

function wfb(idx, f) { return $(`[data-f="${f}"]`, $('#wb' + idx)); }
function setMsgEl(el, text, kind) { el.textContent = text; el.className = 'msg' + (kind ? ' ' + kind : ''); }

function fillChannels(idx, info, channel) {
  const sel = wfb(idx, 'form').channel;
  sel.innerHTML = arr(info.available_channels).map(c =>
    `<option value="${c.c}">${c.c === 0 ? 'Auto' : c.c + (c.c >= 52 && c.c <= 144 ? '  (DFS)' : '')}</option>`).join('');
  sel.value = String(channel);
}
// the widths a channel allows (e.g. 140 is 20 MHz only)
function fillWidths(idx, info, want) {
  const form = wfb(idx, 'form');
  const c = arr(info.available_channels).find(x => String(x.c) === form.channel.value);
  const widths = arr(c ? c.b : info.channelInfo?.bandList).map(String);
  // Auto is bw=0, which the driver resolves per channel (5 GHz: HT160, or
  // HT80 on 149-161 where 160 doesn't fit; 2.4 GHz: HT40) - not the same as
  // forcing a width, so it's offered alongside every fixed one, 160 included.
  form.bandwidth.innerHTML = `<option value="0">Auto</option>` + widths.map(w => `<option value="${w}">${w} MHz</option>`).join('');
  want = String(want ?? form.bandwidth.value);
  form.bandwidth.value = want === '0' || widths.includes(want) ? want : (widths[widths.length - 1] || '0');
}

function syncPwdRow(idx) {
  wfb(idx, 'pwdRow').hidden = wfb(idx, 'form').encryption.value === 'none';
}

function setBandDirty(idx, d) {
  wifiDirty[idx] = d;
  wfb(idx, 'save').disabled = !d;
  setMsgEl(wfb(idx, 'msg'), d ? 'Unsaved changes' : IDLE_MSG);
}

for (const idx of [1, 2]) {
  $('#wb' + idx).innerHTML = bandForm(idx);
  const form = wfb(idx, 'form');
  form.addEventListener('input', () => setBandDirty(idx, true));
  form.addEventListener('change', e => {
    if (e.target.name === 'channel') fillWidths(idx, wifiCur[idx] || {});
    if (e.target.name === 'encryption') syncPwdRow(idx);
    setBandDirty(idx, true);
  });
  wfb(idx, 'eye').addEventListener('click', () => {
    // Field stays type="text" (see bandForm - password type triggers Chrome's
    // "save Wi-Fi password?" prompt); we just toggle the CSS mask on/off.
    form.wpakey.classList.toggle('masked');
  });
  form.addEventListener('submit', e => {
    e.preventDefault();
    const cur = wifiCur[idx] || {};
    const enc = form.encryption.value;
    const ssid = form.ssid.value.trim();
    if (!ssid) return setMsgEl(wfb(idx, 'msg'), 'The network needs a name', 'err');
    if (enc !== 'none' && (form.wpakey.value.length < 8 || form.wpakey.value.length > 63)) return setMsgEl(wfb(idx, 'msg'), 'The password needs 8 to 63 characters', 'err');
    if (enc === 'none' && cur.encryption !== 'none' && !confirm('Make this network open? Anyone nearby could join it without a password.')) return;
    const changedCreds = ssid !== cur.ssid || form.wpakey.value !== cur.password || enc !== cur.encryption;
    if (changedCreds && !confirm(`Save the new ${BANDS[idx].label} name/password?\n\nEvery device on it disconnects and has to join again with the new details - including this one, if it's connected over this Wi-Fi.`)) return;
    withBusy(wfb(idx, 'save'), async () => {
      setMsgEl(wfb(idx, 'msg'), 'Saving - the radio restarts…');
      await stock('wifi_set', {
        wifiIndex: idx, on: 1, ssid, pwd: enc === 'none' ? '' : form.wpakey.value, encryption: enc,
        channel: form.channel.value, bandwidth: form.bandwidth.value, txpwr: form.txpwr.value,
        hidden: form.hidden.checked ? 1 : 0, ax: form.ax.checked ? 1 : 0,
        txbf: cur.txbf ?? 3, weakenable: cur.weakenable ?? 0, weakthreshold: cur.weakthreshold ?? 0, kickthreshold: cur.kickthreshold ?? 0,
      }, ['wifiCfg']);
      setBandDirty(idx, false);
      toast(`${BANDS[idx].label} saved`);
      setTimeout(() => refresh('status'), 8000);
    }).catch(err => setMsgEl(wfb(idx, 'msg'), err.message, 'err'));
  });
  wfb(idx, 'on').addEventListener('change', e => {
    const want = e.target.checked;
    if (!want && !confirm(`Turn ${BANDS[idx].label} Wi-Fi off? Devices on it lose the connection - including this one, if it's on this Wi-Fi.`)) { e.target.checked = true; return; }
    e.target.disabled = true;
    stock(want ? 'wifi_on' : 'wifi_off', { wifiIndex: idx }, ['wifiCfg'])
      .then(() => { toast(`${BANDS[idx].label} ${want ? 'on' : 'off'}`); setTimeout(() => refresh('status'), 8000); })
      .catch(err => { toast(err.message, 'err'); e.target.checked = !want; })
      .finally(() => { e.target.disabled = false; });
  });
}

on('wifiCfg', (d, err) => {
  if (!d) {
    if (err) for (const idx of [1, 2]) setMsgEl(wfb(idx, 'msg'), err.message, 'err');
    return;
  }
  arr(d.info).forEach((info, i) => {
    const idx = i + 1;
    if (!BANDS[idx]) return;
    wifiCur[idx] = info;
    wfb(idx, 'on').checked = info.status === '1';
    if (wifiDirty[idx]) return; // never overwrite an edit that hasn't been saved
    const form = wfb(idx, 'form');
    form.ssid.value = info.ssid || '';
    form.ssid.maxLength = Number(info.ssid_len_limit) || 32;
    form.wpakey.value = info.password || '';
    form.encryption.value = SECURITY.some(x => x[0] === info.encryption) ? info.encryption : 'psk2';
    form.txpwr.value = POWER.some(x => x[0] === info.txpwr) ? info.txpwr : 'max';
    form.hidden.checked = info.hidden === '1';
    form.ax.checked = info.ax === '1';
    // Show the SAVED UCI values in the form (what the user configured), not
    // what the driver is actually running - if 160 MHz on channel 36 got
    // narrowed to 80 MHz on 40 because of DFS, or DFS took a moment, the
    // user still wants to see their own choice in the dropdowns. The live
    // running values go in the pill and in the "actually running" note.
    fillChannels(idx, info, String(info.channel || '0'));
    fillWidths(idx, info, String(info.bandwidth || '0'));
    syncPwdRow(idx);
    updateDriftNote(idx);
  });
});

function updateDriftNote(idx) {
  const cfg = wifiCur[idx] || {};
  const live = Sources.status?.data?.wifi?.[BANDS[idx].key] || {};
  const note = wfb(idx, 'drift');
  if (!note) return;
  const cfgCh = String(cfg.channel || '');
  const cfgBw = String(cfg.bandwidth || '');
  const liveCh = String(live.channel || '');
  const liveBw = String(live.width_mhz || '');
  // Hide when nothing to compare or when what's on air matches the config;
  // Auto (0) for the channel or the width matches whatever the driver chose.
  const chOk = cfgCh === '0' || cfgCh === liveCh;
  const bwOk = cfgBw === '0' || cfgBw === liveBw;
  if (!liveCh || (chOk && bwOk)) { note.hidden = true; return; }
  // Saving applies the change right away, so a mismatch is either the radio
  // still restarting, or - on 5 GHz - the driver leaving a DFS channel after
  // radar, or narrowing the width to fit the channel.
  const what = [!chOk && `channel ${cfgCh}`, !bwOk && `${cfgBw} MHz`].filter(Boolean).join(' at ');
  const why = idx === 2
    ? 'the radio may still be restarting, or the driver moved off a DFS channel or narrowed the width to fit it'
    : 'the radio may still be restarting - give it a few seconds';
  note.hidden = false;
  note.querySelector('span').textContent =
    `Actually running: ch ${liveCh} · ${liveBw} MHz instead of ${what} — ${why}.`;
}

on('status', s => {
  if (!s || !s.wifi) return;
  for (const idx of [1, 2]) {
    const w = s.wifi[BANDS[idx].key] || {};
    const pill = wfb(idx, 'pill');
    if (w.channel) {
      pill.className = 'pill good';
      pill.innerHTML = `ch ${w.channel} · ${w.width_mhz} MHz · ${esc(w.clients || 0)} ${icon('devices')}`;
    } else {
      pill.className = 'pill';
      pill.textContent = 'Off';
    }
    updateDriftNote(idx);
  }
});

// --------------------------------------------------------- channel scan ---

$('#scanBtn').addEventListener('click', e => withBusy(e.currentTarget, async () => {
  const out = $('#scanResult');
  out.innerHTML = '<p class="muted" style="margin:0">Scanning - this takes a few seconds…</p>';
  let d;
  try {
    d = await api('/api/wifi-scan?band=2.4');
  } catch (err) {
    out.innerHTML = '';
    throw err;
  }
  const rec = d.recommendation;
  let html = '';
  if (rec) {
    const scores = Object.entries(rec.scores).map(([ch, sc]) => [Number(ch), sc]).sort((x, y) => x[0] - y[0]);
    const max = Math.max(1, ...scores.map(x => x[1]));
    const current = Number(Sources.status.data?.wifi?.['2.4']?.channel) || null;
    const curScore = rec.scores[String(current)];
    const bestScore = rec.scores[String(rec.best_channel)];
    // Only suggest moving when it's clearly better: scans vary from one run
    // to the next, and a near-tie isn't worth dropping every 2.4 GHz device.
    const closeEnough = curScore != null && curScore - bestScore < Math.max(0.5, curScore * 0.25);
    let msg;
    if (current === rec.best_channel) msg = `<b style="color:var(--text)">Channel ${current} is the clearest.</b> You're already on it.`;
    else if (closeEnough) msg = `<b style="color:var(--text)">Channel ${current} is fine.</b> ${rec.best_channel} scores only slightly lower (${bestScore} vs ${curScore}) - not worth switching.`;
    else msg = `<b style="color:var(--text)">Channel ${rec.best_channel} is the clearest.</b> ` +
      (current ? `You're on ${current} - pick ${rec.best_channel} in the 2.4 GHz card above.` : '');
    html += `<div class="note" style="margin:0 0 14px">${icon('check')}<span>${msg}</span></div>`;
    html += scores.map(([ch, sc]) => `<div class="chan ${ch === rec.best_channel ? 'best' : ''}"><b>Channel ${ch}</b>
      <div class="barw"><i style="width:${Math.max(3, sc / max * 100)}%"></i></div><span class="n">${sc}</span></div>`).join('');
  }
  const chans = (d.channels || []).filter(c => c.channel != null);
  html += `<div class="section-label" style="margin-top:20px">${d.total_networks} networks nearby</div>`;
  html += chans.length ? chans.map(c => {
    const names = (c.networks || []).map(n => n.ssid || 'hidden');
    return `<div class="dev"><div class="avatar"><b>${c.channel}</b></div>
      <div class="main" style="cursor:default"><div class="name">${c.count} network${c.count === 1 ? '' : 's'}</div>
        <div class="meta">${esc(names.slice(0, 4).join(', '))}${names.length > 4 ? ', …' : ''}</div></div>
      <div class="end">${c.strongest_signal != null ? c.strongest_signal + ' dBm' : ''}</div></div>`;
  }).join('') : '<div class="empty">No other networks found.</div>';
  out.innerHTML = html;
}).catch(() => {}));
