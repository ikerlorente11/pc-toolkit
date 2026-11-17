/** The desktop's network for the viewer (its NetBackend): requests to any server (OPDS catalogs,
 * MangaDex, Internet Archive, Komga, Kavita, Calibre-Web…) made by Rust through tauri-plugin-http, so
 * the web view's CORS does not apply, and files downloaded by Rust (src-tauri/src/net.rs) into
 * Downloads\La Estantería (or saved there when the page makes them, `save`, or a piece at a time as it
 * gets them, `saveStream`), answered as the path the shelf's `addFiles` takes. */
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { fetch as rustFetch } from '@tauri-apps/plugin-http'
import { t, type FileSink, type NetBackend } from 'estanteria-viewer'

let agent: Promise<string> | null = null
/** `LaEstanteria/<version> (Windows)`, as Rust says it (one source for both kinds of request). */
function userAgent(): Promise<string> {
  agent ??= invoke<string>('net_user_agent').catch(() => 'LaEstanteria (Windows)')
  return agent
}

function hostOf(url: string): string {
  try { return new URL(url).host } catch (_) { return url }
}

function httpOnly(url: string) {
  if (!/^https?:\/\//i.test(url)) throw new Error(t('Solo se puede acceder a direcciones http o https.'))
}

let downloads = 0

/** A call to Rust whose failure comes as an Error (Rust answers a plain string). */
async function call<T>(run: () => Promise<T>): Promise<T> {
  try {
    return await run()
  } catch (e) {
    throw e instanceof Error ? e : new Error(String(e))
  }
}

export function desktopNet(): NetBackend {
  return {
    async fetch(url, init) {
      httpOnly(url)
      const headers = new Headers(init?.headers)
      if (!headers.has('User-Agent')) headers.set('User-Agent', await userAgent())
      // the server sees an app, not a page of another site: no Origin of the web view (an empty one is left out)
      if (!headers.has('Origin')) headers.set('Origin', '')
      // Rust asks for compressed answers and hands them decompressed; asked by hand, they would come compressed
      headers.delete('Accept-Encoding')
      try {
        // the Response carries the final address after redirects in `url` (relative links resolve against it)
        return await rustFetch(url, { method: init?.method || 'GET', headers, body: init?.body })
      } catch (e) {
        throw new Error(t('No se pudo conectar con {host}: {error}', { host: hostOf(url), error: e instanceof Error ? e.message : String(e) }))
      }
    },

    async download(url, name, headers, progress, folder, signal) {
      httpOnly(url)
      const id = `${Date.now()}-${++downloads}`
      // cancelled: Rust cuts it where it is and deletes what came
      signal?.addEventListener('abort', () => { invoke('net_cancel', { id }).catch(() => {}) }, { once: true })
      const stop = progress
        ? await listen<{ id: string; url: string; done: number; total: number }>('net-download-progress', (e) => {
            if (e.payload.id === id) progress(e.payload.done, e.payload.total)
          })
        : null
      try {
        return await invoke<string>('net_download', { id, url, name, headers: headers || {}, folder: folder || null })
      } catch (e) {
        throw e instanceof Error ? e : new Error(String(e))
      } finally {
        stop?.()
      }
    },

    async save(name, data, folder) {
      // the bytes as the raw body of the call (no JSON array for a file of 100 MB); name and type in headers
      const bytes = new Uint8Array(await data.arrayBuffer())
      try {
        return await invoke<string>('net_save', bytes, {
          headers: { 'x-name': encodeURIComponent(name), 'x-type': encodeURIComponent(data.type || ''), 'x-folder': encodeURIComponent(folder || '') },
        })
      } catch (e) {
        throw e instanceof Error ? e : new Error(String(e))
      }
    },

    async saveStream(name, folder) {
      // Rust writes it as «<name>.part» and gives it its name when whole (net_stream_* in src-tauri/src/net.rs)
      const id = await call(() => invoke<number>('net_stream_open', { name, folder: folder || null }))
      const sink: FileSink = {
        // each piece as the raw body of its call, as `save`; which file, in a header
        write: (piece) => call(() => invoke<void>('net_stream_write', piece, { headers: { 'x-id': String(id) } })),
        close: () => call(() => invoke<string>('net_stream_close', { id })),
        abort: () => call(() => invoke<void>('net_stream_abort', { id })),
      }
      return sink
    },
  }
}
