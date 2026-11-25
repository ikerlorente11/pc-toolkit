<template>
  <ReproductorShell :files="files" :device="device" :view="view" :navigate="navigate" cloud-name="tu nube" :me="me">
    <template #settings><SettingsView :device="device" :version="version" /></template>
  </ReproductorShell>
  <div v-if="dropping" class="rd-drop">Suelta canciones para escucharlas, o carpetas para añadirlas a tu música</div>
</template>

<script setup lang="ts">
import { onBeforeUnmount, onMounted, reactive, ref } from 'vue'
import { getVersion } from '@tauri-apps/api/app'
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { getCurrentWebview } from '@tauri-apps/api/webview'
import {
  DeviceLibrary, ReproductorShell, deviceId, isAudioName, play, queryFromView, viewFromQuery, type Files, type Me, type View
} from 'reproductor-player'
import 'reproductor-player/ui.css'
import { addRoot, desktopDevice, openFile } from './lib/device'
import SettingsView from './SettingsView.vue'

/**
 * El Reproductor for Windows: the shared app (reproductor-player) over the music of this PC (the Rust side
 * indexes the chosen folders and serves the songs). Where the app is lives in the window's hash (#v=album&…),
 * so the mouse's back and forward buttons work.
 */
const device = new DeviceLibrary(desktopDevice())
const version = ref('')
/** This PC among the user's devices (once connected to a server): «Escritorio · NOMBRE-DEL-PC». */
const me = reactive<Me>({ id: deviceId(), name: 'Escritorio', kind: 'desktop' })
invoke<string>('device_name').then((n) => { if (n) me.name = `Escritorio · ${n}` }).catch(() => {})

const files: Files = {
  async list() { throw Object.assign(new Error('Sin servidor conectado'), { status: 404 }) },
  async remove() { throw new Error('Sin servidor conectado') },
  async play(song) {
    if (song.device) return { url: device.backend.fileUrl(song.device) }
    throw new Error('esta canción es de un servidor y no hay ninguno conectado')
  }
}

const readHash = (): View => viewFromQuery(Object.fromEntries(new URLSearchParams(location.hash.replace(/^#/, ''))))
const view = ref<View>(readHash())
function navigate(next: View, replace = false) {
  const hash = '#' + new URLSearchParams(queryFromView(next)).toString()
  if (replace) history.replaceState(null, '', hash)
  else if (hash !== location.hash) history.pushState(null, '', hash)
  view.value = next
}
const onPop = () => { view.value = readHash() }

/** A song opened from the Explorer: on its own, or with the rest of its album when it is in the library. */
async function playPath(path: string) {
  try {
    const track = await openFile(path)
    const album = device.album(device.song(track).albumKey || '')
    const songs = album?.tracks.some((t) => t.id === track.id) ? device.songs(album.tracks) : [device.song(track)]
    play(songs, songs.find((s) => s.device === track.id) || songs[0], false)
  } catch (err: any) {
    console.error(err)
  }
}

// ---- dropping songs (to play) or folders (to add) on the window ----
const dropping = ref(false)
let unlisten: (() => void)[] = []
onMounted(async () => {
  window.addEventListener('popstate', onPop)
  version.value = await getVersion().catch(() => '')
  await device.start().catch((err) => { device.state.error = String(err) })
  const launched = await invoke<string | null>('launch_path')
  if (launched) playPath(launched)
  unlisten.push(await listen<string>('open-file', (e) => playPath(e.payload)))
  unlisten.push(await getCurrentWebview().onDragDropEvent(async (e) => {
    const p = e.payload
    if (p.type === 'enter' || p.type === 'over') { dropping.value = true; return }
    dropping.value = false
    if (p.type !== 'drop') return
    const songs = p.paths.filter((x) => isAudioName(x))
    for (const dir of p.paths.filter((x) => !isAudioName(x) && !/\.[a-z0-9]{2,4}$/i.test(x))) await addRoot(dir).catch(() => {})
    if (songs.length) playPath(songs[0])
  }))
})
onBeforeUnmount(() => {
  window.removeEventListener('popstate', onPop)
  unlisten.forEach((u) => u())
})
</script>
