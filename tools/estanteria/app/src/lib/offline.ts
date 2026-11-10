/** The desktop's keeper of items for reading offline: the Rust side downloads and stores them (see
 * src-tauri/src/offline.rs) and serves them through the `offline` protocol. */
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import type { OfflineBackend, OfflineEntry, OfflineProgress } from 'estanteria-viewer'

/** What the protocol is reached at from the web view (Windows: http://<scheme>.localhost). */
const BASE = navigator.userAgent.includes('Windows') ? 'http://offline.localhost' : 'offline://localhost'

/** One folder per account and service, so two users of the same computer keep their own. */
export function accountKey(username: string, url: string): string {
  let host = url
  try { host = new URL(url).host } catch (_) {}
  return `${username}@${host}`.replace(/[^A-Za-z0-9-]/g, '_')
}

export function desktopBackend(account: string, base: () => string, authorization: () => string): OfflineBackend {
  return {
    list: () => invoke<OfflineEntry[]>('offline_list', { account }),
    start: (job) => invoke('offline_start', {
      job: { account, id: job.id, base: base(), authorization: authorization(), pages: job.pages, file: job.file, width: job.width, meta: job.meta },
    }),
    remove: (id) => invoke('offline_remove', { account, id }),
    url: (id, part) => `${BASE}/${account}/${id}/${part}`,
    onProgress: (handler) => { listen<OfflineProgress>('offline-progress', (e) => handler(e.payload)) },
    where: () => invoke<string>('offline_where', { account }),
  }
}
