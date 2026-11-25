/** Songs of the cloud kept on this PC, as the Rust side makes them (src-tauri/src/cloud.rs): copied into the engine's
 *  music folder with the cloud's own folders, played from there, kept when there is no network. */
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import type { OfflineBackend } from 'reproductor-player'

export function desktopOffline(): OfflineBackend {
  return {
    have: (paths) => invoke<string[]>('offline_have', { paths }),
    get: (paths) => invoke('offline_get', { paths }),
    remove: (paths) => invoke('offline_remove', { paths }),
    onProgress(fn) {
      let off: (() => void) | null = null
      listen<{ done: number; total: number; path?: string | null; error?: string | null }>('offline-progress', (e) => fn(e.payload)).then((u) => { off = u })
      return () => off?.()
    }
  }
}
