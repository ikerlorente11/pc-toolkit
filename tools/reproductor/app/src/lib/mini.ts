/**
 * The mini player's window (the player's MiniPlayer): the app's own window made a card like a trading card, without
 * frame and always on top, where it was left (the first time, at the bottom right of the screen, over the taskbar),
 * and back as it was; or shrunk to a bar, as the phone's widget. Where it is and how big are kept for the next times.
 */
import { getCurrentWindow, LogicalSize, PhysicalPosition, PhysicalSize, currentMonitor } from '@tauri-apps/api/window'
import type { MiniWindow } from 'reproductor-player'

/** the card's size and the bar's (logical pixels) */
const CARD = { w: 300, h: 480 }
const BAR = { w: 380, h: 110 }
const MARGIN = 16
const KEPT = 'reproductor.mini.at'
const COMPACT = 'reproductor.mini.compact'
let compact = (() => { try { return localStorage.getItem(COMPACT) === '1' } catch (_) { return false } })()

const win = getCurrentWindow()
/** how the window was before becoming the card */
let before: { outer: PhysicalSize; at: PhysicalPosition; maximized: boolean } | null = null

/** the screen's area without the taskbar, in physical pixels */
async function area() {
  const m = await currentMonitor()
  if (!m) return null
  const a = m.workArea || { position: m.position, size: m.size }
  return { x: a.position.x, y: a.position.y, w: a.size.width, h: a.size.height, scale: m.scaleFactor }
}

/** where the card's bottom right corner was left (physical pixels), if it was */
function keptCorner(): { right: number; bottom: number } | null {
  try { const v = JSON.parse(localStorage.getItem(KEPT) || 'null'); return v && typeof v.right === 'number' ? v : null } catch (_) { return null }
}
async function keepCorner() {
  try {
    const at = await win.outerPosition()
    const size = await win.outerSize()
    localStorage.setItem(KEPT, JSON.stringify({ right: at.x + size.width, bottom: at.y + size.height }))
  } catch (_) {}
}

/** Puts the card or the bar (as `compact` is) with its bottom right corner where it was, inside the screen. */
async function place() {
  const size = compact ? BAR : CARD
  const a = await area()
  const scale = a?.scale || (await win.scaleFactor())
  await win.setSize(new LogicalSize(size.w, size.h))
  // the size with Windows' invisible border around it (the corner kept is the outer one): with the inner size it
  // moved a few pixels down and right each time
  const outer = await win.outerSize()
  const w = outer.width
  const h = outer.height
  const margin = Math.round(MARGIN * scale)
  const corner = keptCorner() || (a ? { right: a.x + a.w - margin, bottom: a.y + a.h - margin } : null)
  if (!corner) return
  let x = corner.right - w
  let y = corner.bottom - h
  if (a) {
    x = Math.min(Math.max(x, a.x), a.x + a.w - w)
    y = Math.min(Math.max(y, a.y), a.y + a.h - h)
  }
  await win.setPosition(new PhysicalPosition(x, y))
}

let unlisten: (() => void) | null = null

export function desktopMini(on: (mini: boolean) => void): MiniWindow {
  return {
    async enter() {
      if (before) return
      before = { outer: await win.outerSize(), at: await win.outerPosition(), maximized: await win.isMaximized() }
      on(true)
      if (before.maximized) await win.unmaximize()
      await win.setMinSize(null)
      await win.setDecorations(false)
      await win.setAlwaysOnTop(true)
      await win.setResizable(false)
      await place()
      // moved by hand: where it is now is kept
      let timer: ReturnType<typeof setTimeout> | null = null
      unlisten = await win.onMoved(() => { if (timer) clearTimeout(timer); timer = setTimeout(keepCorner, 400) })
    },
    async exit() {
      if (!before) return
      const was = before
      before = null
      unlisten?.()
      unlisten = null
      await keepCorner()
      await win.setAlwaysOnTop(false)
      await win.setDecorations(true)
      await win.setResizable(true)
      await win.setMinSize(new LogicalSize(720, 480))
      // its size with its frame as it was (the inner size alone came back a few pixels smaller each time)
      const inner = await win.innerSize()
      const outer = await win.outerSize()
      await win.setSize(new PhysicalSize(was.outer.width - (outer.width - inner.width), was.outer.height - (outer.height - inner.height)))
      await win.setPosition(was.at)
      if (was.maximized) await win.maximize()
      on(false)
    },
    get compact() { return compact },
    async setCompact(on: boolean) {
      compact = on
      try { localStorage.setItem(COMPACT, on ? '1' : '0') } catch (_) {}
      if (!before) return
      await keepCorner()
      await place()
    }
  }
}
