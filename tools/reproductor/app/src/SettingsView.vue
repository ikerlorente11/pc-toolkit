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
import type { DeviceLibrary } from 'reproductor-player'

const props = defineProps<{ device: DeviceLibrary; version: string }>()
const lib = props.device.state
const countIn = (root: string) => { const r = root.toLowerCase(); return lib.tracks.filter((t) => t.path.toLowerCase().startsWith(r)).length }
async function add() { try { await props.device.backend.addRoot() } catch (err: any) { lib.error = err?.message || String(err) } }
async function remove(root: string) {
  if (!window.confirm(`¿Dejar de leer «${root}»? Sus canciones salen de El Reproductor, pero no se borra ningún archivo.`)) return
  await props.device.backend.removeRoot(root)
}
</script>
