<template>
  <div v-if="ready" class="up-banner" role="status">
    <span><strong>{{ name }} {{ ready }}</strong> está lista. Se instalará al cerrar la app.</span>
    <button class="up-now" :disabled="busy" @click="now">Reiniciar ahora</button>
    <button class="up-close" title="Más tarde" aria-label="Más tarde" @click="ready = ''">✕</button>
  </div>
</template>

<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from 'vue'
import { invoke } from '@tauri-apps/api/core'

/**
 * The app updating itself when PC Toolkit does not (src-tauri/src/updater.rs): a minute after opening and every six
 * hours it looks for a newer release and downloads it; then this says so, and it installs on «Reiniciar ahora» or
 * when the app closes. Nothing shows when PC Toolkit takes care of it. The same file in La Estantería and El Reproductor.
 */
const props = defineProps<{ name: string }>()
const name = props.name
const ready = ref('')
const busy = ref(false)
let timer: any = null
async function check() {
  try {
    const s = await invoke<{ managed: boolean; ready: string | null }>('update_check')
    if (!s.managed && s.ready) ready.value = s.ready
  } catch (_) { /* offline, or GitHub not answering: next time */ }
}
async function now() {
  busy.value = true
  try { await invoke('update_install') } catch (_) { busy.value = false }
}
onMounted(() => {
  timer = setTimeout(function again() { check(); timer = setTimeout(again, 6 * 3600 * 1000) }, 60 * 1000)
})
onBeforeUnmount(() => clearTimeout(timer))
</script>

<style scoped>
.up-banner { position: fixed; right: 16px; bottom: 104px; z-index: 80; display: flex; align-items: center; gap: 12px; max-width: min(560px, calc(100vw - 32px));
  padding: 10px 12px 10px 16px; border-radius: 12px; background: var(--oc-role-surface-container-high, #313137); color: var(--oc-role-on-surface, #ededf2);
  box-shadow: 0 10px 30px rgba(0, 0, 0, .35); font: 13px/1.4 system-ui, "Segoe UI", sans-serif; }
.up-now { padding: 6px 14px; border: 0; border-radius: 999px; background: #1fb866; color: #04170c; font-weight: 700; cursor: pointer; }
.up-now:disabled { opacity: .6; cursor: default; }
.up-close { border: 0; background: transparent; color: inherit; cursor: pointer; font-size: 14px; opacity: .7; }
</style>
