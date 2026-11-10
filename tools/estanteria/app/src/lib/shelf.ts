/** The desktop's shelf: folders and files of this PC, listed, unpacked and rendered by the Rust side
 * (src-tauri/src/local.rs) and served through the `shelf` protocol. */
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { open } from '@tauri-apps/plugin-dialog'
import type { LocalFile, LocalRoot, Prepared, ShelfBackend, ShelfConfig, UploadDone } from 'estanteria-viewer'

/** What the protocol is reached at from the web view (Windows: http://<scheme>.localhost). */
const BASE = navigator.userAgent.includes('Windows') ? 'http://shelf.localhost' : 'shelf://localhost'
const EXTENSIONS = ['cbz', 'cbr', 'cb7', 'zip', 'rar', '7z', 'epub', 'pdf']

function list(picked: string | string[] | null): string[] {
  return picked === null ? [] : Array.isArray(picked) ? picked : [picked]
}

/** `service` and `authorization`: where the account's La Estantería is and how to ask it (for uploads). */
export function desktopShelf(service: () => string, authorization: () => string): ShelfBackend {
  return {
    config: () => invoke<ShelfConfig>('shelf_config'),
    scan: () => invoke<LocalFile[]>('shelf_scan'),
    pickFolders: async () => list(await open({ directory: true, multiple: true, title: 'Carpetas con cómics y libros' })),
    pickFiles: async () => list(await open({ multiple: true, title: 'Cómics y libros', filters: [{ name: 'Cómics y libros', extensions: EXTENSIONS }] })),
    addRoot: (path) => invoke<LocalRoot>('shelf_add_root', { path }),
    removeRoot: (id) => invoke('shelf_remove_root', { id }),
    renameRoot: (id, name) => invoke('shelf_rename_root', { id, name }),
    addFile: (path) => invoke<LocalFile>('shelf_add_file', { path }),
    removeFile: (id) => invoke('shelf_remove_file', { id }),
    prepare: (id) => invoke<Prepared>('shelf_prepare', { id }),
    url: (id, part) => {
      const [kind, n] = part.split('/')
      return n !== undefined ? `${BASE}/${kind}/${id}/${n}` : `${BASE}/${kind}/${id}`
    },
    setCacheLimit: (bytes) => invoke('shelf_set_cache_limit', { bytes }),
    clearCache: () => invoke('shelf_clear_cache'),
    reveal: (id) => invoke('shelf_reveal', { id }),
    upload: async (id, dest, progress) => {
      const stop = await listen<{ id: number; sent: number; total: number }>('shelf-upload', (e) => { if (e.payload.id === id) progress(e.payload.sent, e.payload.total) })
      try {
        return await invoke<UploadDone>('shelf_upload', { id, base: service(), authorization: authorization(), dest })
      } finally { stop() }
    },
  }
}
