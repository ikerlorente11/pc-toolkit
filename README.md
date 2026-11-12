# PC Toolkit

<img src="assets/pc-toolkit.png" width="72" align="right" alt="">

Mi librería de pequeñas utilidades para Windows, con **un solo instalador** y un
**gestor en la bandeja del sistema** (al estilo de PowerToys) para activarlas,
configurarlas, instalarlas o quitarlas.

Funciona en Windows 10/11, **sin permisos de administrador** y sin instalar nada
aparte de PowerShell, que ya viene con Windows. Las herramientas que integran programas de
otros (**Everything**, **LocalSend** y **Jarvis**) los instalan solas si faltan; de todas ellas,
solo Everything pide permisos de administrador, una vez, para su servicio de indexado.

## Herramientas

| Herramienta | Qué hace |
|---|---|
| **Audio AutoSwitch** | Cambia la salida de audio al conectar un dispositivo (auriculares Bluetooth, USB...) y vuelve al anterior disponible al desconectarlo. Cambio rápido desde el panel o con **Ctrl + Alt + A**. |
| **Jarvis** | Asistente de voz con [OpenJarvis](https://github.com/open-jarvis/OpenJarvis): pulsa **Ctrl + Alt + J**, habla y te responde en voz alta en castellano, con una voz local gratuita o una de [ElevenLabs](https://elevenlabs.io). Entiende y piensa en tu PC (Whisper + Ollama). |
| **Barra de tareas** | Configura posición, ocultación automática, alineación y tamaño de los iconos, búsqueda y pantallas de la barra de tareas, con un perfil independiente para Escritorio remoto. Botón y atajo (**Ctrl + Alt + B**) para restablecerla cuando la ocultación automática deja de responder. |
| **Everything** | Con **Ctrl + Alt + F** abre una ventana para buscar cualquier archivo o carpeta del PC por su nombre al instante, con el índice de [Everything](https://www.voidtools.com) (voidtools). Abre el resultado, su carpeta o copia su ruta sin tocar el ratón. |
| **Juegos** | Al abrir cada juego de la lista, desactiva el HDR de su pantalla mientras está abierto (los juegos sin HDR se ven lavados con él) y lo pone en ventana sin bordes ocupando justo la pantalla elegida: se ve como en pantalla completa, pero no se minimiza al pasar a otra pantalla. |
| **Modo juegos** | Los emuladores (KytyPS5...) van mucho más lentos con el hipervisor de Windows (Hyper-V/VBS), que WSL2 y Docker necesitan. Crea una entrada de arranque sin hipervisor ni VBS: se cambia de modo desde su tarjeta o desde el aviso que sale al abrir un emulador (y al abrir Docker o WSL en modo juegos, ofrece volver). El modo se mantiene en cada reinicio hasta que lo cambies. Pide administrador una sola vez, al instalarla. |
| **La Estantería** | Lector de cómics, manga y libros (cbz, cbr, cb7, pdf, djvu, epub, mobi, fb2…) de tus carpetas, de catálogos y de bibliotecas ([tu Archivador](https://github.com/ikerlorente11/estanteria), OPDS, Komga, Kavita, WebDAV, Suwayomi), con el progreso, notas y marcadores sincronizados con la web y el móvil. **Ctrl + Alt + L** la abre; los cómics y libros del Explorador se abren con ella. |
| **Keyboard Sound** | Reproduce un sonido al pulsar cada tecla. Varios sonidos, volumen propio (sin tocar el del sistema), campo de prueba y opción de iniciar con Windows. |
| **LocalSend** | Pasa archivos entre el PC, el móvil y otros ordenadores de la red local, sin cuenta ni Internet, con [LocalSend](https://localsend.org). Lo deja en la bandeja para recibir y lo añade al menú **Enviar a** del Explorador. |
| **Sonidos de dispositivos** | Cambia los sonidos de Windows al conectar y desconectar un dispositivo (USB...) por otros de una biblioteca: espada, Discord, Windows XP, globo, memes... Al desactivarla vuelven los de Windows. |
| **Traductor** | Con **Ctrl + Alt + T** abre una ventana para traducir palabras o textos entre más de 35 idiomas, con detección automática del idioma, traducción mientras escribes y copia con una tecla. |

## Instalar en un PC nuevo

**[⬇ Descargar PCToolkit-Setup.exe](https://github.com/ikerlorente11/pc-toolkit/releases/latest/download/PCToolkit-Setup.exe)**,
ábrelo, marca las herramientas que quieras y pulsa **Instalar**. El instalador
descarga siempre la última versión, así que el `.exe` sirve aunque sea antiguo.

> Como el `.exe` no está firmado, Windows puede mostrar *"Windows protegió su PC"*:
> pulsa **Más información → Ejecutar de todas formas**.

No hay que configurar nada al instalar: todo se ajusta después desde el gestor.

Sin descargar nada, desde **PowerShell** (normal, sin admin):

```powershell
irm https://raw.githubusercontent.com/ikerlorente11/pc-toolkit/main/install.ps1 | iex
```

Desde el repo clonado también puedes hacerlo sin preguntas:

```powershell
git clone https://github.com/ikerlorente11/pc-toolkit.git
cd pc-toolkit
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Tools all            # todas
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Tools taskbar-rdp    # solo algunas
```

Si en ese PC ya tenías instaladas las versiones sueltas antiguas
(`audio-autoswitch`, `taskbar-rdp`), el instalador las migra solo y conserva la
configuración de los auriculares.

## El gestor

Pulsa el icono de PC Toolkit en la bandeja del sistema: se abre un panel abajo a
la derecha, como el de PowerToys (redondeado, con fondo de cristal en Windows 11 y
el tema y color de acento de tu Windows). También está en el menú Inicio y, por
defecto, arranca con Windows.

- **Instaladas**: interruptor para activarlas o desactivarlas sin desinstalarlas;
  pulsa una para entrar en sus ajustes, ver su registro o desinstalarla.
- **Disponibles**: botón **Instalar**. Todo se hace en segundo plano con una barra
  de progreso, sin congelar el panel.
- **Vista** (botón junto a la rueda dentada): alterna entre lista (con descripción y el
  cambio rápido de audio) y cuadrícula (mosaicos compactos de 2 en 2).
- **Grupos plegables**: pulsa "Instaladas" o "Disponibles" para plegarlos o desplegarlos.
  La vista y los grupos plegados se recuerdan.
- **Orden**: en Ajustes → Portada → Orden de las herramientas se cambia con flechas; por
  defecto es alfabético por nombre.
- **Ajustes** (rueda dentada): iniciar con Windows, actualizaciones (ver abajo), abrir la
  carpeta y salir.

### Actualizaciones

PC Toolkit y los programas que instalan algunas herramientas (**La Estantería**, **LocalSend** y
**Everything**) se actualizan cada uno por su lado, sin reinstalar nada:

- El gestor busca versiones nuevas en segundo plano, sin congelar el panel: un minuto y medio después de
  arrancar y luego cada 6 horas. **Ajustes → Actualizaciones → Buscar actualizaciones** revisa en ese momento
  PC Toolkit y todas las apps, y lista lo que tiene versión nueva, cada una con su botón **Actualizar** (y
  **Actualizar todo** si hay varias), o dice que todo está al día.
- La página de cada herramienta con app tiene su sección **Actualizaciones**: versión instalada y última,
  botón **Actualizar** (con su progreso y su registro, como instalar) y el interruptor **Actualizar
  automáticamente**. PC Toolkit tiene el suyo en Ajustes. Por defecto están apagados.
- Con el interruptor activado, la versión nueva se instala sola y sale un aviso al terminar
  («La Estantería 0.5.1 · Actualización instalada»). Si la app está abierta **no se cierra**: se vuelve a
  intentar cada 30 minutos hasta que la cierres. PC Toolkit se actualiza solo con el panel cerrado y vuelve a
  la bandeja; al arrancar la versión nueva lo avisa.
- Con el interruptor apagado, se avisa: «Actualización disponible» en su tarjeta de la portada y en su página,
  un aviso arriba en la portada para PC Toolkit y el texto del icono de la bandeja.
- El botón **Actualizar** sí cierra la app si está abierta (lo has pedido tú) y la vuelve a abrir si hacía falta
  (LocalSend, Everything).
- Everything se instala para todo el equipo y actualizarlo pide **permisos de administrador**, así que nunca se
  actualiza solo: solo avisa, y al pulsar Actualizar Windows pregunta.
- Lo último que se encontró se guarda en `data\updates.json` (así no se pregunta a GitHub en cada repintado: son
  dos consultas a su API por revisión) y los interruptores en `data\manager.json`. Jarvis no entra: su entorno de
  Python y OpenJarvis se rehacen al reinstalarlo, y Ollama se actualiza solo.

### Audio AutoSwitch

- **Cambio rápido**: en la portada del panel, debajo de Audio AutoSwitch, sale el
  dispositivo que suena; púlsalo y elige en la lista desplegable entre tus dispositivos
  habilitados que estén conectados.
- **Ctrl + Alt + A**: pasa al siguiente dispositivo habilitado conectado y muestra un aviso
  abajo en el centro (como el de volumen). Funciona mientras PC Toolkit esté en la bandeja.
  Se cambia (o se desactiva) en la página de la herramienta → Atajo de teclado.

En su página de ajustes:

- **Sonando ahora**: cambia a mano entre los dispositivos conectados sin apagar nada.
- **Dispositivos habilitados**: los que se ponen solos al encenderse y los únicos que
  salen en el cambio rápido y en el atajo. Por
  defecto, los Bluetooth, los USB y los auriculares; no los monitores HDMI ni los
  altavoces internos (si Windows cambia solo a un monitor que despierta, se vuelve
  a lo que sonaba).
- **Dispositivo por defecto**: al que volver cuando ya no queda nada encendido, o
  ninguno para que decida Windows.
- **Usar también su micrófono**: el micro sigue al dispositivo de salida.

### Barra de tareas

- **Perfil normal** y **perfil de Escritorio remoto** (opcional; si está desactivado se aplica
  el normal). Cada perfil define: posición (abajo o arriba; también a los lados en
  Windows 10), ocultación automática, alineación y tamaño de los iconos, búsqueda (oculta,
  icono o cuadro) y si la barra aparece en todas las pantallas. Se aplican al iniciar sesión,
  al conectarse por Escritorio remoto y al volver a la sesión local.
- **Refrescar** (botón en la portada y en su página, o **Ctrl + Alt + B**): restablece la
  barra cuando la ocultación automática deja de responder.

> Cambiar la posición reinicia el Explorador de Windows. Windows 11 no admite la barra en
> los laterales (queda vacía), por eso ahí solo se ofrece abajo y arriba.

### Everything

- **Ctrl + Alt + F** (o el botón **Buscar** de la portada) abre una ventana arriba, centrada; busca
  **mientras escribes** en el índice de Everything, que responde en milisegundos aunque haya millones de
  archivos. Vale su sintaxis: `*.pdf`, `ext:mp4 vacaciones`, `size:>1gb`...
- **Intro** abre el resultado, **Ctrl + Intro** abre su carpeta con él seleccionado,
  **Ctrl + Mayús + Intro** lo abre como administrador y **Ctrl + Mayús + C** copia su ruta. Las flechas
  mueven la selección y **Esc** cierra. También hay botones para abrir la ubicación y copiar la ruta.
- En sus ajustes: el **orden** (nombre, fecha de modificación, ruta o tamaño), mostrar u ocultar
  **carpetas**, **buscar también en la ruta**, **ocultar la papelera de reciclaje** y si la ventana se
  cierra al hacer clic fuera. También muestra si Everything está en marcha, con botón para iniciarlo.
- Al instalarla, si Everything no está instalado, lo instala con winget (el MSI oficial, con su
  servicio de indexado): Windows pide **permisos de administrador una vez** y, si se rechazan, la
  instalación se cancela. Si ya lo tenías, no pide nada. La tarea arranca Everything en la bandeja al
  iniciar sesión (es el que atiende las búsquedas); la ventana vive en el gestor, así que abre al instante.
- Desinstalar la herramienta no desinstala Everything (se quita desde Configuración > Aplicaciones).
- **Actualizaciones**: la última versión se lee de [voidtools.com](https://www.voidtools.com/downloads/) y se
  actualiza con winget. Como pide permisos de administrador, no se actualiza sola: avisa en su tarjeta y en su
  página, y al pulsar **Actualizar** Windows pregunta (Everything se cierra un momento y vuelve a la bandeja).

### La Estantería

- App de escritorio propia (`tools/estanteria/app`, [Tauri 2](https://tauri.app): WebView2 + Rust) que reutiliza el visor
  compartido del repo [estanteria](https://github.com/ikerlorente11/estanteria) (`viewer/`): inicio con seguir leyendo,
  novedades y series; biblioteca con búsqueda; visor de cómic (una o dos páginas, tira vertical, zoom, sentido manga) y
  de libros (letra, interlineado, márgenes, temas); notas, subrayados y marcadores, todo guardado en El Archivador.
- También lee archivos de este PC (carpetas añadidas como bibliotecas, o abiertos con doble clic o arrastrados):
  cómics cbz, cbr, cb7 y cbt (páginas jpg, png, webp, gif, avif, bmp y jxl; el jxl se pasa a jpg), pdf, djvu/djv
  y libros epub, mobi/azw/azw3, fb2, fbz (o `.fb2.zip`) y txt, con su portada. El instalador asocia cbz, cbr, cb7, cbt,
  djvu, djv, epub, mobi, azw, azw3, fb2 y fbz (pdf como alternativa; txt no, para no quitársela al Bloc de notas).
- Es un lector local por defecto: sin conectar nada lee los archivos de este PC. En «Bibliotecas → Añadir» se conecta
  El Archivador (dirección, usuario y una **contraseña de aplicación**, que va al almacén de credenciales de Windows;
  una dirección que no responde no se guarda) y, en Catálogos, catálogos públicos, OPDS y las fuentes de Suwayomi
  (eligiendo qué idiomas de cada extensión se ven).
- Descargas: una carpeta a elegir en Ajustes (por defecto `Descargas\La Estantería`). Lo de los catálogos va en
  `<serie>/`, las copias para leer sin conexión en `<nombre de la biblioteca>/<su carpeta en El Archivador>/`: un
  cómic o un PDF baja entero (varios a la vez, se pueden cancelar) y las páginas se sacan o se pintan aquí. Lo que
  solo usa la app (fichas, portadas, páginas preparadas) queda en `%LOCALAPPDATA%\com.ikerlorente11.estanteria\offline`.
  Al cambiar de carpeta se mueve todo (las ids, y con ellas el progreso, no cambian).
- Subir a El Archivador una carpeta de este PC: solo lo que falta allí (se mira antes), varios a la vez, en la carpeta
  de su serie; se puede cancelar.
- El CI compila el instalador en Windows cuando cambia `tools/estanteria/app` y, con una etiqueta `estanteria-v<versión>`,
  lo publica en Releases; la herramienta descarga la última release y la instala para el usuario actual (sin admin).
  El gestor ve las releases nuevas solo (ver [Actualizaciones](#actualizaciones)): publicar una versión de la app **no
  necesita subir `VERSION`** de PC Toolkit. Si está abierta, ni la actualización automática ni reinstalar la herramienta
  la cierran; el botón Actualizar de su página sí.
  Para publicar una versión nueva: subir `version` en `src-tauri/tauri.conf.json`, `package.json`, `Cargo.toml` y
  `Cargo.lock`, mover el visor (`estanteria-viewer` en `package.json` y `pnpm-lock.yaml`) al commit del repo estanteria
  y añadir sus novedades a `viewer/src/lib/changelog.ts` (las enseña Ajustes → Acerca de), y etiquetar.
- Desarrollo: `cd tools/estanteria/app && pnpm install && pnpm tauri dev` (hace falta Rust y las herramientas de
  compilación de C++ de Visual Studio); solo la parte web, `pnpm dev` en el navegador.

### Juegos

- **Juegos**: lista de ejecutables (por defecto, The Binding of Isaac: `isaac-ng.exe`). Para añadir
  uno, ábrelo y elígelo en **Elegir un programa abierto**, o escribe el nombre de su `.exe`.
- Cada juego tiene dos opciones:
  - **Desactivar el HDR mientras está abierto**: se apaga solo en la pantalla del juego (la elegida
    para la ventana sin bordes o, si no, en la que esté su ventana) y se vuelve a encender al cerrarlo
    (también al desactivar la herramienta). Si ya estaba apagado, no se toca.
  - **Ventana sin bordes a pantalla completa**: con el juego en modo ventana, le quita los bordes y
    lo coloca ocupando la **pantalla** elegida. Si el juego vuelve a poner el borde, se corrige solo
    en un segundo. Para cambiarlo de pantalla: deja el ratón **arriba del todo** en su pantalla y
    sale una barra con **◀ ▶** (como la barra de tareas al bajarlo), o **Ctrl + Alt + P** (pasa el juego
    abierto a la siguiente), **Win + Mayús + ← / →** o el selector de su tarjeta; se recuerda para la
    próxima vez.
  - **Mostrar la barra de tareas al bajar el ratón**: deja 1 píxel libre abajo. Si la ventana ocupa la
    pantalla entera, Windows la trata como pantalla completa y no saca la barra oculta encima.
- **HDR ahora**: interruptor por pantalla para cambiarlo a mano (como **Win + Alt + B**).

### Keyboard Sound

- **Sonido**: pato, rana, maullido, "ahh" o "yiahhh"; al elegirlo se reproduce una muestra.
- **Volumen**: el de los sonidos, sin cambiar el del sistema.
- **Probar**: campo para escribir y escuchar el sonido y el volumen elegidos.
- **Iniciar con Windows**: si está desactivado, solo suena mientras la herramienta esté activada.

### LocalSend

- Con la herramienta activada, **LocalSend se inicia oculto en la bandeja** al iniciar sesión para que
  el PC aparezca en el móvil y pueda recibir archivos. En la portada sale con qué nombre lo ven los demás
  dispositivos.
- **Enviar** (portada) o **Enviar archivos...** (ajustes): eliges los archivos y LocalSend se abre con
  ellos listos para mandarlos. **Clic derecho > Enviar a > LocalSend** en el Explorador hace lo mismo
  (se puede quitar en sus ajustes; es el mismo acceso que crea la opción "Menú contextual" de LocalSend).
- Al instalarla, si LocalSend no está instalado, lo instala con winget **para el usuario actual, sin
  permisos de administrador**. La primera vez que recibe, Windows puede preguntar si le permites
  acceder a la red: acéptalo para las redes privadas.
- Al desactivarla deja de iniciarse solo y se quita de **Enviar a**; si está abierto no se cierra (podría
  estar pasando archivos). Desinstalar la herramienta no desinstala LocalSend.
- **Actualizaciones**: mira la última release de [LocalSend en GitHub](https://github.com/localsend/localsend/releases)
  y lo actualiza con winget. Si solo está oculto en la bandeja, se cierra, se actualiza y se vuelve a abrir oculto
  (también en automático); con su ventana abierta, la actualización automática espera a que la cierres. Si winget
  todavía no tiene la versión recién publicada, se vuelve a intentar en la siguiente revisión.

### Sonidos de dispositivos

- Un sonido para **conectar** y otro para **desconectar**, elegidos de la biblioteca (o el
  predeterminado de Windows, o sin sonido); al elegirlo suena una muestra.
- **Volumen** propio para estos sonidos (se aplica a una copia del sonido, sin tocar el volumen
  del resto de sonidos del sistema).
- **Probar** reproduce los sonidos que Windows tiene configurados en ese momento.
- No hay proceso en segundo plano: cambia los sonidos del sistema de tu usuario y los
  vuelve a aplicar al iniciar sesión. Al desactivarla o desinstalarla vuelven los de Windows.

### Traductor

- **Ctrl + Alt + T** (o el botón **Abrir** de la portada) abre una ventana abajo a la derecha, en la esquina;
  el mismo atajo o **Esc** la cierran. Se puede arrastrar por la cabecera.
- Traduce **mientras escribes** y **detecta el idioma**. Si el texto ya está en el idioma de destino, lo
  traduce al **alternativo** (por defecto: a español y, si ya está en español, a inglés).
- Para palabras sueltas muestra **otras traducciones** por categoría (sustantivo, verbo...).
- **Intro** traduce ya, **Mayús + Intro** añade una línea, **Ctrl + Intro** copia la traducción y cierra,
  **Ctrl + Mayús + S** (o la flecha doble) intercambia los idiomas. Los idiomas tienen buscador.
- En sus ajustes, los **idiomas por defecto** (desde cuál, a cuál y el alternativo) y si se cierra al hacer
  clic fuera. Lo que se cambie en la ventana dura hasta cerrarla.
- Usa el servicio de Google Translate (sin cuenta ni clave), así que necesita Internet. No hay proceso en
  segundo plano: la ventana vive en el gestor y por eso abre al instante.

### Jarvis

- **Ctrl + Alt + J**: suena un pitido y te escucha hasta que te callas; lo transcribe con Whisper, lo piensa
  con un modelo de Ollama a través de OpenJarvis y te lo dice con la voz elegida. Si lo pulsas mientras
  habla, se calla. Recuerda los últimos turnos durante 5 minutos, por si quieres seguir la conversación.
  Mientras hablas ya carga el modelo, y con una gráfica NVIDIA Whisper va en ella: responde en menos de un
  segundo y medio desde que te callas.
- **Voz en tu PC** (gratis y sin internet, con acento de España): Dave (por defecto), Sharvard (mujer u
  hombre) con [Piper](https://github.com/rhasspy/piper), o Dora y Alex con Kokoro.
- **Voz de ElevenLabs** (más natural, gasta créditos): Daniel, George, Brian, Lily, Sara Martin u **otra voz**
  pegando su enlace o ID de [elevenlabs.io/voices](https://elevenlabs.io/voices). Hace falta su **clave**
  (solo con el permiso *Text to Speech*), que se guarda cifrada para tu usuario de Windows. Las voces de la
  biblioteca (como Sara Martin) necesitan un plan de pago para usarse por API; si una voz falla, habla Dave.
  **Modelo de ElevenLabs**: Multilingüe v2 (la más natural) o Flash v2.5 (responde antes y gasta la mitad).
- **Probar voz** la escucha al momento.
- **Modelo de IA**: cualquiera de los que tengas en Ollama (por defecto, qwen3:8b).
- **Abrir chat de voz**: abre el chat de OpenJarvis (`jarvis chat --voice`) con la misma voz y modelo.
- La instalación no pide administrador: usa Python 3.10-3.13 (si no hay, instala el 3.13 para tu usuario),
  crea un entorno propio con OpenJarvis y las voces locales (con NVIDIA, también CUDA para Whisper), instala Ollama si falta y descarga qwen3:8b si no tienes ningún
  modelo (la primera vez son varios GB). Al desinstalarla se borran su entorno, las voces y el modelo de Whisper;
  Ollama y sus modelos se quedan, por si los usas para otras cosas.

> Los sonidos de Keyboard Sound y de Sonidos de dispositivos proceden de
> [myinstants.com](https://www.myinstants.com), recortados y normalizados.

> Los cascos con receptor USB (p. ej. Razer Barracuda X) solo "se encienden" para
> Windows al enchufar el receptor: con los cascos apagados el receptor sigue
> apareciendo como un dispositivo activo y no avisa de nada (comprobado también por
> su canal HID). Para esos, usa el cambio rápido o Ctrl + Alt + A.

## Actualizar y desinstalar

```powershell
# Actualizar (o Ajustes › Actualizaciones en el gestor, que también puede hacerlo solo)
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/ikerlorente11/pc-toolkit/main/install.ps1))) -Update

# Desinstalar todo (o desde Configuración > Aplicaciones > PC Toolkit)
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\PcToolkit\app\uninstall.ps1"
```

## Cómo está hecho

```
install.ps1 / uninstall.ps1   instalador global
core/Toolkit.psm1             funciones comunes (estado, activar, instalar...)
core/run-hidden.vbs           lanza scripts de PowerShell sin ventana
manager/PcToolkit.ps1         gestor: icono de bandeja + panel WPF (theme.xaml, flyout.xaml)
core/tool-action.ps1          ejecuta instalar/activar/actualizar... en segundo plano para el gestor
core/update-check.ps1         busca versiones nuevas de PC Toolkit y de las apps, en segundo plano
setup/                        PCToolkit-Setup.exe (C#; se compila con setup/build.ps1)
tools/<id>/                   una carpeta por herramienta
```

Se instala en `%LOCALAPPDATA%\PcToolkit` (fuera de OneDrive):
`app\` con el código y `data\<id>\` con la configuración y los logs de cada herramienta.

Cada herramienta es una **tarea programada** de Windows (con el nombre que diga su
`tool.json`): sin tarea = no instalada, tarea deshabilitada = desactivada.

### Añadir una herramienta nueva

Crea `tools/<id>/` con:

| Archivo | Obligatorio | Qué hace |
|---|---|---|
| `tool.json` | sí | `id`, `name`, `icon` (código hex de un icono de Segoe Fluent Icons), `summary` (3-4 palabras para la portada), `category` (tema con el que se agrupa en la portada: Sonido, Escritorio, Juegos, Apps), `description`, `task` (nombre de la tarea), `process` (regex de su script si se queda en marcha), `log` (nombre del log en su carpeta de datos), `installNote` (opcional: aviso junto al botón Instalar si no se instala "para el usuario, sin admin") |
| `install.ps1` | sí | Registra la tarea programada (usa `New-HiddenTaskAction` de `core/Toolkit.psm1`). Si integra un programa de otro fabricante, lo instala con `Install-WingetPackage` (`-Elevated` si necesita admin: Windows pregunta) y cuenta el progreso con `Set-ToolStatus` |
| `settings.ps1` | no | Página de ajustes dentro del panel; usa los helpers descritos al principio de `manager/PcToolkit.ps1` (nada de ventanas de Windows) |
| `home.ps1` | no | Bloque dentro de su tarjeta en la portada del panel (mismos helpers) |
| `hotkey` en `tool.json` | no | `{ "keys": "Ctrl+Alt+A", "script": "x.ps1" }`: atajo global mientras esté activa (el usuario puede cambiarlo; se guarda en `data\hotkeys.json`); el script devuelve el texto del aviso (si no devuelve nada, no hay aviso) |
| `disable.ps1` | no | Deja el sistema como estaba al desactivarla |
| `update.ps1` + `"updates": true` en `tool.json` | no | Si instala un programa con versiones propias: con `-Action info` devuelve `Installed` (versión instalada), `InUse` (está abierto y actualizarlo obligaría a cerrarlo) y `Elevated` (actualizarlo pide admin: entonces nunca se actualiza solo); con `-Action latest`, la última versión publicada (pocas llamadas a la red); con `-Action update`, lo actualiza y devuelve la versión nueva (con `-Auto`, sin cerrarlo nunca). El gestor añade la sección Actualizaciones y lo revisa con los demás (ver `core/Toolkit.psm1`) |

El gestor y el instalador la detectan solos. Sube `VERSION` para que los PCs
instalados vean la actualización del código de PC Toolkit (las apps con `update.ps1` no lo necesitan).

## Licencia

Puedes usar, modificar y compartir este proyecto libremente para fines **no comerciales**.
No está permitido venderlo ni ganar dinero con él. Ver [LICENSE](LICENSE) (PolyForm Noncommercial 1.0.0).
