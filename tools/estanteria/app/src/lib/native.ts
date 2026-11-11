/** What the desktop's native side adds to the viewer: «save as» (the system's dialog, from Rust) and the
 * lock, Windows Hello (face, fingerprint or the account's PIN), asked by Rust over the app's window (see
 * src-tauri/src/lock.rs). The rest of NativeFeatures (volume keys, Wi-Fi only, share) is for phones. */
import { invoke } from '@tauri-apps/api/core'
import type { FileToHand, NativeFeatures } from 'estanteria-viewer'

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
  }
}
