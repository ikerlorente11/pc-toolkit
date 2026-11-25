<template>
  <section class="rp-page rd-settings">
    <header class="rp-page-head"><h1 class="rp-h1">Ajustes</h1></header>

    <section class="rd-box">
      <h2>Música de este equipo</h2>
      <p class="rp-muted rp-small">El Reproductor lee las canciones de estas carpetas (y de sus subcarpetas). Las que cambien se vuelven a leer solas al abrir la app.</p>
      <ul v-if="lib.roots.length" class="rd-roots">
        <li v-for="r in lib.roots" :key="r">
          <i class="rp-i rp-i-folder" aria-hidden="true"></i>
          <span class="rp-ellipsis" :title="r">{{ r }}</span>
          <span class="rp-muted rp-small">{{ countIn(r) }} canciones</span>
          <button class="rp-mini" title="Dejar de leer esta carpeta (no se borra nada)" @click="remove(r)"><i class="rp-i rp-i-close" aria-hidden="true"></i></button>
        </li>
      </ul>
      <p v-else class="rp-muted">Ninguna carpeta: añade la tuya.</p>
      <div class="rd-actions">
        <button class="rp-btn rp-primary" @click="add"><i class="rp-i rp-i-folder-add" aria-hidden="true"></i> Añadir carpeta</button>
        <button class="rp-btn" :disabled="lib.scanning" @click="device.backend.scan()">
          <span v-if="lib.scanning" class="rp-spin"></span><i v-else class="rp-i rp-i-refresh" aria-hidden="true"></i> Volver a leer
        </button>
        <span class="rp-muted rp-small">
          <template v-if="lib.scanning && lib.progress.total">Leyendo {{ lib.progress.done }} de {{ lib.progress.total }}…</template>
          <template v-else>{{ lib.tracks.length }} canciones · {{ device.albums.length }} discos · {{ device.artists.length }} artistas</template>
        </span>
      </div>
      <p v-if="lib.error" class="rp-banner rp-banner-error">{{ lib.error }}</p>
    </section>

    <section class="rd-box">
      <h2>Descargas</h2>
      <p class="rp-muted rp-small">«Descargar música» baja canciones a este equipo con su propio motor (soundlift): todo ocurre aquí, sin servidor.</p>
      <template v-if="es.status?.installed">
        <p class="rp-small">
          Motor {{ es.status.installed.replace(/^motor-v/, '') }}
          <span class="rp-muted"> · yt-dlp {{ es.status.ytdlp || es.status.info?.ytdlp || '—' }}<template v-if="es.status.running"> · en marcha</template></span>
        </p>
        <p class="rp-small">Se guardan en <a href="#" :title="es.status.music_dir" @click.prevent="engine.backend.openMusicDir()">{{ es.status.music_dir }}</a></p>
        <div class="rd-actions">
          <button class="rp-btn" @click="chooseDir(false)"><i class="rp-i rp-i-folder-open" aria-hidden="true"></i> Cambiar carpeta</button>
          <button class="rp-btn" :disabled="checking" title="Buscar una versión más nueva de yt-dlp (YouTube cambia a menudo)" @click="updateYtdlp">
            <span v-if="checking" class="rp-spin"></span><i v-else class="rp-i rp-i-refresh" aria-hidden="true"></i> Actualizar yt-dlp</button>
          <button v-if="engine.updatable" class="rp-btn rp-primary" :disabled="es.installing" @click="engine.install()">
            <span v-if="es.installing" class="rp-spin"></span> Instalar el motor {{ es.latest!.tag.replace(/^motor-v/, '') }}</button>
        </div>
      </template>
      <p v-else class="rp-muted rp-small">El motor aún no está instalado: se instala la primera vez que entras en «Descargar música».</p>
      <p v-if="es.error" class="rp-banner rp-banner-error">{{ es.error }}</p>
    </section>

    <section class="rd-box">
      <h2>Servidor</h2>
      <p class="rp-muted">Conectado a un servidor de El Reproductor verás toda la música de tu nube, podrás seguir artistas y bajar música. Llegará en la próxima versión.</p>
    </section>

    <section class="rd-box">
      <h2>El Reproductor</h2>
      <p class="rp-muted rp-small">Versión {{ version || '—' }}. Las canciones que te gustan, tus listas y lo que escuchas se guardan en este equipo.</p>
    </section>
  </section>
</template>

<script setup lang="ts">
import { onMounted, ref } from 'vue'
import type { DeviceLibrary, LocalEngine } from 'reproductor-player'

const props = defineProps<{ device: DeviceLibrary; engine: LocalEngine; version: string }>()
const es = props.engine.state
const checking = ref(false)
async function chooseDir(reset: boolean) {
  try {
    const dir = await props.engine.backend.chooseMusicDir(reset)
    if (dir) await props.engine.refresh()
  } catch (err: any) { es.error = err?.message || String(err) }
}
async function updateYtdlp() {
  checking.value = true
  try { await props.engine.backend.updateYtdlp(true); await props.engine.refresh() } catch (err: any) { es.error = err?.message || String(err) } finally { checking.value = false }
}
onMounted(async () => { await props.engine.refresh().catch(() => {}); if (es.status?.installed) props.engine.findLatest() })
const lib = props.device.state
const countIn = (root: string) => { const r = root.toLowerCase(); return lib.tracks.filter((t) => t.path.toLowerCase().startsWith(r)).length }
async function add() { try { await props.device.backend.addRoot() } catch (err: any) { lib.error = err?.message || String(err) } }
async function remove(root: string) {
  if (!window.confirm(`¿Dejar de leer «${root}»? Sus canciones salen de El Reproductor, pero no se borra ningún archivo.`)) return
  await props.device.backend.removeRoot(root)
}
</script>
