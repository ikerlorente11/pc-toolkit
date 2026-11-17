/** What the desktop's native side adds to the viewer: «save as» (the system's dialog, from Rust), the
 * lock, Windows Hello (face, fingerprint or the account's PIN), asked by Rust over the app's window (see
 * src-tauri/src/lock.rs), and its secure store, Windows' Credential Manager (a Telegram session). The rest
 * of NativeFeatures (volume keys, Wi-Fi only, share) is for phones. */
import { invoke } from '@tauri-apps/api/core'
import { t, type FileToHand, type NativeFeatures } from 'estanteria-viewer'

/** The viewer's secrets, in the same place as the server's app token (src-tauri/src/lib.rs) under accounts
 * of their own: a server's user is never `viewer:…`. */
const account = (key: string) => `viewer:${key}`
/** The longest secret the Credential Manager keeps: 2560 bytes (CRED_MAX_CREDENTIAL_BLOB_SIZE) of UTF-16,
 * so 1280 UTF-16 units, which is what a string's `length` counts. A Telegram session (StringSession, about
 * 350-400 characters) fits with room; nothing longer is kept in pieces, since nothing needs it. */
const MAX_SECRET = 1280

export function desktopNative(): NativeFeatures {
  return {
    // the dialog is shown by Rust (src-tauri/src/net.rs): the page hands the bytes, never a path
    async saveAs(file: FileToHand) {
      const bytes = new Uint8Array(await (await file.blob()).arrayBuffer())
      const path = await invoke<string | null>('net_save_as', bytes, { headers: { 'x-name': encodeURIComponent(file.name) } })
      return !!path
    },
    lock: {
      available: () => invoke<boolean>('lock_available').catch(() => false),
      // `reason` is the line the Windows Hello dialog shows
      unlock: (reason) => invoke<boolean>('lock_unlock', { reason }).catch(() => false),
    },
    secrets: {
      // a store that does not answer counts as nothing kept (as the server's token, see settings.ts)
      get: async (key) => { try { return (await invoke<string | null>('secret_get', { account: account(key) })) ?? null } catch (_) { return null } },
      async set(key, value) {
        if (value !== null && value.length > MAX_SECRET) throw new Error(t('No se puede guardar: Windows no guarda secretos tan largos.'))
        try {
          if (value === null) await invoke<void>('secret_delete', { account: account(key) })
          else await invoke<void>('secret_set', { account: account(key), secret: value })
        } catch (e) {
          // Rust answers a plain string
          throw e instanceof Error ? e : new Error(String(e))
        }
      },
    },
  }
}
