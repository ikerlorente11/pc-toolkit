/** A server of El Reproductor of its own (El Archivador's): its address, user and name in a settings file, the app
 *  password in Windows' Credential Manager (through the Rust side). Connected, the app is the server's El Reproductor:
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

/** Connects: asks the service who it is and where the cloud is, hands it the app password if it has none of this
 *  user yet (it downloads in the background with it) and tells the Rust side how to reach the cloud's songs. */
export async function connect(c: Connection, password?: string): Promise<Server> {
  const url = c.url.trim().replace(/\/+$/, '')
  const connection = { ...c, url }
  const secret = password ?? ((await invoke<string | null>('secret_get', { account: account(connection) }).catch(() => null)) || '')
  if (!secret) throw new Error('falta la contraseña de aplicación')
  let info: { name?: string; webdav?: string; soundlift?: string | null; local?: boolean }
  try {
    const res = await tauriFetch(`${url}/api/info`)
    info = await res.json()
  } catch (err: any) {
    throw new Error(`no responde ${url} (${err?.message || err})`)
  }
  if (info.name !== 'reproductor' || !info.webdav) throw new Error('esa dirección no es un servidor de El Reproductor')
  const auth = Api.basic(connection.username, secret)
  const api = new Api(url, auth)
  api.fetch = (input, init) => tauriFetch(input, init)
  let status: { connected: boolean }
  try {
    status = await api.cloud()
  } catch (err: any) {
    throw new Error(err?.status === 401 ? 'el usuario o la contraseña de aplicación no son correctos' : err?.message || String(err))
  }
  if (!status.connected) await api.connectCloud(secret)
  await invoke('cloud_set', { webdav: info.webdav, user: connection.username, password: secret })
  const sl = new Soundlift(info.soundlift || '', auth)
  sl.fetch = api.fetch
  if (password !== undefined) {
    const s = await file()
    await s.set('server.url', url)
    await s.set('server.username', connection.username)
    await s.set('server.name', connection.name.trim())
    await invoke('secret_set', { account: account(connection), secret: password })
  }
  return { connection, api, sl }
}

export async function disconnect(c: Connection): Promise<void> {
  const s = await file()
  await s.delete('server.url')
  await s.delete('server.username')
  await s.delete('server.name')
  await invoke('secret_delete', { account: account(c) }).catch(() => {})
  await invoke('cloud_set', {})
}
