# PC Toolkit

<img src="assets/pc-toolkit.png" width="72" align="right" alt="">

Mi librería de pequeñas utilidades para Windows, con **un solo instalador** y un
**gestor en la bandeja del sistema** (al estilo de PowerToys) para activarlas,
configurarlas, instalarlas o quitarlas.

Funciona en Windows 10/11, **sin permisos de administrador** y sin instalar nada
aparte de PowerShell, que ya viene con Windows.

## Herramientas

| Herramienta | Qué hace |
|---|---|
| **Audio AutoSwitch** | Lo último que enciendes (cascos Bluetooth o USB) pasa a sonar; al apagarlo vuelve al anterior que siga encendido y, al final, a tu dispositivo por defecto. Cambio rápido desde el panel o con **Ctrl + Alt + A**. |
| **Taskbar RDP** | Barra de tareas siempre visible cuando te conectas por Escritorio Remoto y autoocultable cuando estás delante del PC. |

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
- **Ajustes** (rueda dentada): iniciar con Windows, buscar actualizaciones (se
  instalan solas respetando lo que tengas activado), abrir la carpeta y salir.

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

> Los cascos con receptor USB (p. ej. Razer Barracuda X) solo "se encienden" para
> Windows al enchufar el receptor: con los cascos apagados el receptor sigue
> apareciendo como un dispositivo activo y no avisa de nada (comprobado también por
> su canal HID). Para esos, usa el cambio rápido o Ctrl + Alt + A.

## Actualizar y desinstalar

```powershell
# Actualizar (o el botón del gestor)
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
core/tool-action.ps1          ejecuta instalar/activar/... en segundo plano para el gestor
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
| `tool.json` | sí | `id`, `name`, `icon` (código hex de un icono de Segoe Fluent Icons), `description`, `task` (nombre de la tarea), `process` (regex de su script si se queda en marcha), `log` (nombre del log en su carpeta de datos) |
| `install.ps1` | sí | Registra la tarea programada (usa `New-HiddenTaskAction` de `core/Toolkit.psm1`) |
| `settings.ps1` | no | Página de ajustes dentro del panel; usa los helpers descritos al principio de `manager/PcToolkit.ps1` (nada de ventanas de Windows) |
| `home.ps1` | no | Bloque dentro de su tarjeta en la portada del panel (mismos helpers) |
| `hotkey` en `tool.json` | no | `{ "keys": "Ctrl+Alt+A", "script": "x.ps1" }`: atajo global mientras esté activa (el usuario puede cambiarlo; se guarda en `data\hotkeys.json`); el script devuelve el texto del aviso |
| `disable.ps1` | no | Deja el sistema como estaba al desactivarla |

El gestor y el instalador la detectan solos. Sube `VERSION` para que los PCs
instalados vean la actualización.

## Licencia

Puedes usar, modificar y compartir este proyecto libremente para fines **no comerciales**.
No está permitido venderlo ni ganar dinero con él. Ver [LICENSE](LICENSE) (PolyForm Noncommercial 1.0.0).
