/** A server of El Reproductor of its own (El Archivador's): its address, user and name in a settings file, the app
 *  password in Windows' Credential Manager (through the Rust side). The user types their normal password once: the app
 *  makes with it an app password of its own in the cloud (as the web does), keeps only that one and forgets theirs, so
 *  nobody has to make or copy app passwords. Connected, the app is the server's El Reproductor:
 *  the cloud's music (played through Rust, see src-tauri/src/cloud.rs), its downloads, its playlists. */
import { invoke } from '@tauri-apps/api/core'
import { fetch as tauriFetch } from '@tauri-apps/plugin-http'
import { load, type Store } from '@tauri-apps/plugin-store'
import { Api, Soundlift } from 'reproductor-player'

export interface Connection {
  url: string
  username: string
  /** what the user called it (where deleted songs go: «la papelera de …») */
  name: string
}

/** The server connected: its API, soundlift (if it has one) and what it said of itself. */
export interface Server {
  connection: Connection
  api: Api
  sl: Soundlift
}

let store: Store | null = null
async function file(): Promise<Store> {
  if (!store) store = await load('settings.json', { autoSave: true, defaults: {} })
  return store
}

export async function savedConnection(): Promise<Connection | null> {
  const s = await file()
  const url = ((await s.get<string>('server.url')) || '').replace(/\/+$/, '')
  const username = (await s.get<string>('server.username')) || ''
  return url && username ? { url, username, name: (await s.get<string>('server.name')) || '' } : null
}

const account = (c: Connection) => `${c.username}@${new URL(c.url).host}`

/** An app password of this app in the cloud (OpenCloud's /auth-app/tokens), made with the user's normal one. */
async function mintAppPassword(cloud: string, username: string, password: string, device: string): Promise<string> {
  const q = new URLSearchParams({ label: `El Reproductor · ${device}`.slice(0, 100), expiry: '8760h' })
  let res: Response
  try {
    res = await tauriFetch(`${cloud}/auth-app/tokens?${q}`, { method: 'POST', headers: { Authorization: Api.basic(username, password)() } })
  } catch (err: any) {
    throw new Error(`no responde ${cloud} (${err?.message || err})`)
  }
  if (res.status === 401) throw Object.assign(new Error('el usuario o la contraseña no son correctos'), { status: 401 })
  if (!res.ok) throw new Error(`tu nube no deja crear una contraseña para la app (HTTP ${res.status})`)
  const token = String((await res.json().catch(() => ({})))?.token || '').trim()
  if (!token) throw new Error('tu nube no devolvió la contraseña de la app')
  return token
}

/** Connects: asks the service who it is and where the cloud is, hands it the app password if it has none of this
 *  user yet (it downloads in the background with it) and tells the Rust side how to reach the cloud's songs.
 *  `password` (connecting from Ajustes): the user's normal one, which only makes the app's own. A saved connection
 *  from before that holds a normal password gets its app password now (`server.app` says it is one). */
export async function connect(c: Connection, password?: string, device = 'Escritorio'): Promise<Server> {
  const url = c.url.trim().replace(/\/+$/, '')
  const connection = { ...c, url }
  const s = await file()
  let secret = password ?? ((await invoke<string | null>('secret_get', { account: account(connection) }).catch(() => null)) || '')
  if (!secret) throw Object.assign(new Error('vuelve a escribir tu contraseña'), { status: 401 })
  let fresh = password !== undefined || !(await s.get<boolean>('server.app'))
  let info: { name?: string; cloud?: string; webdav?: string; soundlift?: string | null; local?: boolean }
  try {
    const res = await tauriFetch(`${url}/api/info`)
    info = await res.json()
  } catch (err: any) {
    throw new Error(`no responde ${url} (${err?.message || err})`)
  }
  if (info.name !== 'reproductor' || !info.webdav) throw new Error('esa dirección no es un servidor de El Reproductor')
  if (fresh) secret = await mintAppPassword(info.cloud || info.webdav.replace(/\/remote\.php\/webdav$/, ''), connection.username, secret, device)
  const auth = Api.basic(connection.username, secret)
  const api = new Api(url, auth)
  api.fetch = (input, init) => tauriFetch(input, init)
  let status: { connected: boolean }
  try {
    status = await api.cloud()
  } catch (err: any) {
    // the app's password was revoked or ran out: the user writes theirs again
    throw Object.assign(new Error(err?.status === 401 ? 'tu sesión ha caducado: vuelve a escribir tu contraseña' : err?.message || String(err)),
                        { status: err?.status })
  }
  if (!status.connected) await api.connectCloud(secret)
  await invoke('cloud_set', { webdav: info.webdav, user: connection.username, password: secret })
  const sl = new Soundlift(info.soundlift || '', auth)
  sl.fetch = api.fetch
  if (fresh) {
    await s.set('server.url', url)
    await s.set('server.username', connection.username)
    await s.set('server.name', connection.name.trim())
    await invoke('secret_set', { account: account(connection), secret })   // only the app's: the user's is forgotten
    await s.set('server.app', true)
    fresh = false
  }
  return { connection, api, sl }
}

export async function disconnect(c: Connection): Promise<void> {
  const s = await file()
  await s.delete('server.url')
  await s.delete('server.username')
  await s.delete('server.name')
  await s.delete('server.app')
  await invoke('secret_delete', { account: account(c) }).catch(() => {})
  await invoke('cloud_set', {})
}
