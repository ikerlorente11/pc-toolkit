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

/** `library`: the library's name as the person calls it, the folder its copies go in (in the downloads folder). */
export function desktopBackend(account: string, base: () => string, authorization: () => string, library: () => string = () => ''): OfflineBackend {
  return {
    // a book, a comic archive or a PDF comes whole: a few at once fill the line better than one
    parallel: 3,
    list: () => invoke<OfflineEntry[]>('offline_list', { account }),
    start: (job) => invoke('offline_start', {
      job: { account, id: job.id, base: base(), authorization: authorization(), pages: job.pages, file: job.file, width: job.width, meta: job.meta, library: library() },
    }),
    remove: (id) => invoke('offline_remove', { account, id }),
    url: (id, part) => `${BASE}/${account}/${id}/${part}`,
    onProgress: (handler) => { listen<OfflineProgress>('offline-progress', (e) => handler(e.payload)) },
    where: () => invoke<string>('offline_where', { account }),
  }
}
