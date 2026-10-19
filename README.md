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
| **Audio AutoSwitch** | Al encender los auriculares Bluetooth pasa la salida de sonido (y opcionalmente el micro) a ellos; al apagarlos vuelve a los altavoces. |
| **Taskbar RDP** | Barra de tareas siempre visible cuando te conectas por Escritorio Remoto y autoocultable cuando estás delante del PC. |

## Instalar en un PC nuevo

**[⬇ Descargar PCToolkit-Setup.exe](https://github.com/ikerlorente11/pc-toolkit/releases/latest/download/PCToolkit-Setup.exe)**,
ábrelo, marca las herramientas que quieras y pulsa **Instalar**. El instalador
descarga siempre la última versión, así que el `.exe` sirve aunque sea antiguo.

> Como el `.exe` no está firmado, Windows puede mostrar *"Windows protegió su PC"*:
> pulsa **Más información → Ejecutar de todas formas**.

Si eliges Audio AutoSwitch, **ten los auriculares encendidos**: se abrirá una
ventana para elegirlos (y los altavoces y micros de respaldo).

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

Está en el menú Inicio (**PC Toolkit**) y, por defecto, arranca con Windows en la
bandeja del sistema.

- **Interruptor**: activa o desactiva la herramienta sin desinstalarla.
- **Configurar**: vuelve a elegir dispositivos (Audio AutoSwitch).
- **Ver log**: abre su registro de actividad.
- **Instalar / Desinstalar**: añade o quita la herramienta en este PC.
- **Buscar actualizaciones**: compara con la versión de GitHub y se actualiza
  respetando lo que tengas activado o desactivado.

Clic derecho en el icono de la bandeja para activar o desactivar herramientas
rápidamente.

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
manager/PcToolkit.ps1         gestor (WinForms + icono de bandeja)
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
| `tool.json` | sí | `id`, `name`, `description`, `task` (nombre de la tarea), `process` (regex de su script si se queda en marcha), `log` (nombre del log en su carpeta de datos) |
| `install.ps1` | sí | Registra la tarea programada (usa `New-HiddenTaskAction` de `core/Toolkit.psm1`) |
| `configure.ps1` | no | Ventana de configuración; devuelve `$true` si se guardó |
| `disable.ps1` | no | Deja el sistema como estaba al desactivarla |

El gestor y el instalador la detectan solos. Sube `VERSION` para que los PCs
instalados vean la actualización.

## Licencia

Puedes usar, modificar y compartir este proyecto libremente para fines **no comerciales**.
No está permitido venderlo ni ganar dinero con él. Ver [LICENSE](LICENSE) (PolyForm Noncommercial 1.0.0).
