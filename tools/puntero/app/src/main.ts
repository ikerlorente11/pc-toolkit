// The window of El Puntero: the pairing QR and code, the phones paired and a few settings. It asks
// Rust for the status every couple of seconds; while it does, pairing stays open (state.rs).
import { invoke } from '@tauri-apps/api/core'

interface Device { id: string; name: string; added: number; last_seen: number; connected: boolean }
interface Status {
  version: string; name: string; computer: string; port: number; listening: boolean; error: string | null; firewall: string | null
  addresses: string[]; code: string; qr: string; link: string; devices: Device[]; autostart: boolean
}

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T
let lastQr = ''
let nameEdited = false

function ago(seconds: number): string {
  if (!seconds) return 'nunca'
  const diff = Date.now() / 1000 - seconds
  if (diff < 90) return 'hace un momento'
  if (diff < 3600) return `hace ${Math.round(diff / 60)} min`
  if (diff < 86400) return `hace ${Math.round(diff / 3600)} h`
  return new Date(seconds * 1000).toLocaleDateString('es-ES', { day: 'numeric', month: 'short' })
}

function render(s: Status) {
  const state = $('state')
  const connected = s.devices.filter(d => d.connected)
  if (!s.listening) {
    state.className = 'state bad'
    state.textContent = s.error ?? 'No está escuchando'
  } else {
    state.className = 'state ok'
    state.textContent = connected.length
      ? `Controlado desde ${connected.map(d => d.name).join(', ')}`
      : s.addresses.length ? 'Listo, esperando al móvil' : 'Listo, pero sin red: conéctate a la wifi'
  }
  $('firewall').hidden = !s.firewall || !s.listening
  if (s.firewall) $('firewall-text').textContent = s.firewall
  if (s.qr !== lastQr) { $('qr').innerHTML = s.qr; lastQr = s.qr }
  $('code').textContent = s.code.replace(/^(\d{3})(\d{3})$/, '$1 $2')

  $('devices').replaceChildren(...s.devices.map(d => {
    const li = document.createElement('li')
    const dot = document.createElement('span')
    dot.className = d.connected ? 'dot on' : 'dot'
    const name = document.createElement('div')
    name.className = 'name'
    const b = document.createElement('b')
    b.textContent = d.name
    const info = document.createElement('span')
    info.textContent = d.connected ? 'Conectado ahora' : `Última vez ${ago(d.last_seen)}`
    name.append(b, info)
    const remove = document.createElement('button')
    remove.textContent = 'Quitar'
    remove.title = 'Este móvil tendrá que volver a emparejarse'
    remove.onclick = async () => { await invoke('remove_device', { id: d.id }); refresh() }
    li.append(dot, name, remove)
    return li
  }))
  $('no-devices').hidden = s.devices.length > 0

  const nameInput = $<HTMLInputElement>('name')
  if (!nameEdited && document.activeElement !== nameInput) { nameInput.value = s.name; nameInput.placeholder = s.computer }
  $<HTMLInputElement>('autostart').checked = s.autostart
  $('addresses').textContent = s.addresses.length ? `Direcciones de este PC: ${s.addresses.join(', ')} · puerto ${s.port}` : ''
  $('version').textContent = `Versión ${s.version}.`
}

async function refresh() {
  try { render(await invoke<Status>('status')) } catch (e) { console.error(e) }
}

$<HTMLInputElement>('name').addEventListener('input', () => { nameEdited = true })
$<HTMLInputElement>('name').addEventListener('change', async e => {
  await invoke('set_name', { name: (e.target as HTMLInputElement).value })
  nameEdited = false
  refresh()
})
$<HTMLButtonElement>('firewall-fix').addEventListener('click', async e => {
  const button = e.currentTarget as HTMLButtonElement
  const note = $('firewall-note')
  button.disabled = true
  note.textContent = 'Esperando el permiso de Windows…'
  try {
    await invoke('allow_firewall')
    note.textContent = 'Hecho. Comprobando…'
  } catch (err) {
    note.textContent = String(err)
  } finally {
    button.disabled = false
    setTimeout(refresh, 3500)
  }
})
$<HTMLInputElement>('autostart').addEventListener('change', async e => {
  try { await invoke('set_autostart', { on: (e.target as HTMLInputElement).checked }) } finally { refresh() }
})

// only while the window is visible: hidden in the tray, pairing closes on its own
setInterval(() => { if (document.visibilityState === 'visible') refresh() }, 2000)
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') refresh() })
refresh()
