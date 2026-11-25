/** The music of this PC, as the Rust side keeps it (src-tauri/src/library.rs): the index, its folders and the
 *  `media` protocol that serves the songs (with ranges, for seeking), their covers and their .lrc. */
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { open } from '@tauri-apps/plugin-dialog'
import type { DeviceBackend, DeviceTrack } from 'reproductor-player'

/** Where a custom protocol answers: http://<scheme>.localhost on Windows (WebView2), <scheme>://localhost elsewhere. */
const base = navigator.userAgent.includes('Windows') ? 'http://media.localhost' : 'media://localhost'

export const mediaUrl = (path: string) => `${base}/${path}`

export function desktopDevice(): DeviceBackend {
  return {
    get: () => invoke<{ roots: string[]; tracks: DeviceTrack[]; scanning: boolean }>('library_get'),
    scan: () => invoke('library_scan'),
    async addRoot() {
      const dir = await open({ directory: true, multiple: false, title: 'Elige una carpeta con música' })
      if (!dir || Array.isArray(dir)) return false
      await invoke('library_add_root', { path: dir })
      return true
    },
    removeRoot: (path) => invoke('library_remove_root', { path }),
    reveal: (path) => invoke('library_reveal', { path }),
    async lyrics(id) {
      const res = await fetch(mediaUrl(`l/${id}`))
      return res.ok ? res.text() : null
    },
    fileUrl: (id) => mediaUrl(`f/${id}`),
    coverUrl: (cover) => mediaUrl(`c/${cover}`),
    onProgress(fn) {
      let off: (() => void) | null = null
      listen<{ done: number; total: number }>('library-progress', (e) => fn(e.payload)).then((u) => { off = u })
      return () => off?.()
    },
    onChanged(fn) {
      let off: (() => void) | null = null
      listen<string | null>('library-changed', (e) => fn(e.payload)).then((u) => { off = u })
      return () => off?.()
    }
  }
}

/** A song opened from the Explorer (or dropped on the window), read for the player. */
export const openFile = (path: string) => invoke<DeviceTrack>('library_open_file', { path })
export const addRoot = (path: string) => invoke('library_add_root', { path })
