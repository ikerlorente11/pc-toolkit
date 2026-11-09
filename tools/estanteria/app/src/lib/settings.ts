/** Where La Estantería is and who you are: the address and user in a settings file, the app
 * token in Windows' credential store (through the Rust side). */
import { invoke } from '@tauri-apps/api/core'
import { load, type Store } from '@tauri-apps/plugin-store'

export interface Connection {
  url: string
  username: string
}

const DEFAULT_URL = 'https://estanteria.pistation.dev'
let store: Store | null = null

async function file(): Promise<Store> {
  if (!store) store = await load('settings.json', { autoSave: true, defaults: {} })
  return store
}

export async function loadConnection(): Promise<Connection> {
  const s = await file()
  return { url: ((await s.get<string>('url')) || DEFAULT_URL).replace(/\/+$/, ''), username: (await s.get<string>('username')) || '' }
}

export async function saveConnection(connection: Connection): Promise<void> {
  const s = await file()
  await s.set('url', connection.url.replace(/\/+$/, ''))
  await s.set('username', connection.username)
}

export async function loadToken(username: string): Promise<string> {
  if (!username) return ''
  try { return (await invoke<string | null>('secret_get', { account: username })) || '' } catch (_) { return '' }
}

export async function saveToken(username: string, token: string): Promise<void> {
  await invoke('secret_set', { account: username, secret: token })
}

export async function forgetToken(username: string): Promise<void> {
  try { await invoke('secret_delete', { account: username }) } catch (_) { /* nothing stored */ }
}
