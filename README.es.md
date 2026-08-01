<p align="center">
  <img src=".github/assets/KeeForge-iOS-Default-1024x1024@1x.png" alt="Icono de la app KeeForge" width="128" />
</p>

<h1 align="center">KeeForge</h1>

<p align="center">
  <a href="README.md">English</a> | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | Español
</p>

<p align="center">
  Un gestor de KeePass gratuito y de código abierto para iPhone y iPad.
  <br />
  SwiftUI nativo, almacenamiento local, autorrelleno, llaves de acceso, TOTP, sincronización en la nube, edición de KDBX y visualización de archivos adjuntos.
</p>

<p align="center">
  <a href="https://apps.apple.com/us/app/keeforge/id6759309295">
    <img alt="Descargar en App Store" src="https://img.shields.io/badge/App%20Store-Download-0D96F6?style=for-the-badge&logo=appstore&logoColor=white" />
  </a>
  <img alt="Swift LoC" src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Ftokei.kojix2.net%2Fapi%2Fgithub%2FKeeForge%2FKeeForge%2Flanguages&query=%24.data.languages.Swift.code&label=swift%20loc&color=orange&style=for-the-badge" />
  <a href="LICENSE">
    <img alt="Licencia: GPLv3" src="https://img.shields.io/badge/license-GPLv3-blue?style=for-the-badge" />
  </a>
</p>

## ¿Por qué KeeForge?

KeeForge es un cliente nativo de KeePass para iOS pensado para quienes quieren que su bóveda siga siendo suya. Abra bases de datos `.kdbx` desde Archivos, iCloud Drive, carpetas locales, Dropbox, OneDrive o servidores WebDAV como Nextcloud y Synology; desbloquéela con una contraseña maestra, un archivo de clave o datos biométricos; y luego explore, busque, edite, guarde y use el autorrelleno sin confiar su bóveda a un servicio de contraseñas alojado.

## Beta pública

Las nuevas versiones se publican en TestFlight antes de llegar a la App Store.

**[Únase a la beta de KeeForge en TestFlight](https://testflight.apple.com/join/mPAT4f1a)**

> [!WARNING]
> **Pruebe con una copia de su base de datos, no con su bóveda principal.** Las compilaciones beta no están revisadas y comparten el identificador de paquete y el contenedor con la app de la App Store, por lo que abren sus archivos `.kdbx` reales.

Las plazas están limitadas a 300 probadores, y la incorporación se cierra mientras una nueva versión está en revisión beta de Apple, así que el enlace no siempre está disponible.

## Funciones destacadas

| Área | Qué hace KeeForge |
| --- | --- |
| **Compatibilidad con KeePass** | Lee y escribe bases de datos KDBX 4.x con cifrado AES-256, ChaCha20 o Twofish, y AES-KDF, Argon2d o Argon2id. También abre bases de datos KDBX 3.1 en modo de solo lectura. |
| **Edición local** | Cree, edite y elimine entradas; cree y elimine grupos; y guarde con comprobación de conflictos, copias de seguridad con marca de tiempo, y conservación del historial de entradas y del XML desconocido. |
| **Nuevas bases de datos** | Cree nuevas bases de datos KDBX 4.x de forma local o directamente en carpetas de Dropbox, OneDrive y WebDAV. |
| **Claves compuestas** | Desbloquee con contraseña, archivo de clave o ambos, incluidos archivos de clave binarios, hexadecimales, XML v1/v2 (`.key`/`.keyx`) y arbitrarios. |
| **Autorrelleno** | Autorrelleno en Safari y en apps, sugerencias QuickType, creación de credenciales desde la extensión, y desbloqueo protegido con Face ID. |
| **Llaves de acceso** | Detecta y autentica llaves de acceso FIDO2/WebAuthn almacenadas en campos personalizados compatibles con KeePassXC. |
| **TOTP** | Visualización en vivo de contraseñas de un solo uso, función de copiar, cuentas regresivas, y autorrelleno de códigos de verificación a partir de iOS 18. |
| **Sincronización en la nube** | Exploración nativa y sincronización de lectura/escritura para Dropbox, OneDrive y WebDAV, copias compartidas en caché para el autorrelleno, subidas en cola desde la extensión, y comprobación de conflictos. |
| **Archivos adjuntos** | Vea los archivos adjuntos de las entradas de KeePass, obtenga una vista previa de los archivos compatibles con QuickLook, y compártalos desde archivos temporales protegidos de corta duración. La edición de archivos adjuntos aún no es compatible. |
| **Listo para iPad** | La navegación adaptativa usa un espacio de trabajo de bóveda en vista dividida en pantallas más anchas, mientras mantiene el flujo compacto del iPhone centrado y nativo. |
| **Seguridad** | Cifrado AES-GCM de secretos en memoria, retardo tras desbloqueos fallidos, límites contra bombas de descompresión, y comparación HMAC en tiempo constante. |

## Privacidad

KeeForge no tiene analítica, ni telemetría en segundo plano, ni SDK de informes de fallos. Los datos de la bóveda permanecen en el dispositivo y en las ubicaciones de almacenamiento que usted elija. El acceso a la red se limita a los proveedores de nube conectados, la obtención opcional de favicones a través de DuckDuckGo, las compras opcionales en la App Store para la propina, y el formulario de comentarios integrado en la app cuando usted envía explícitamente un mensaje.

Todo lo que copie permanece en el dispositivo en el que lo copió, nunca se sincroniza con sus otros dispositivos, y se borra por sí solo al cabo de un rato o al bloquear la base de datos. KeeForge también oculta lo que hay en pantalla mientras esta se está grabando o reflejando.

Lea la [política de privacidad](https://keeforge.com/es/privacy) ([original en inglés](https://keeforge.com/privacy)).

## Seguridad de los datos

KeeForge se toma muy en serio la seguridad de los datos: un gestor de contraseñas nunca debe corromper su bóveda ni perder silenciosamente ninguna parte de ella. Antes de publicar cualquier cambio, pruebas automatizadas verifican que:

- **No se pierde nada al guardar.** Cada tipo de edición se guarda y se vuelve a leer pieza por pieza — contraseñas, notas, archivos adjuntos, historial de entradas e incluso datos de otras apps de KeePass que KeeForge no reconoce deben volver exactamente como se introdujeron.
- **Su archivo está protegido antes de tocarlo.** KeeForge se niega a sobrescribir cambios hechos desde otro lugar mientras usted tenía el archivo abierto, escribe una copia de seguridad con marca de tiempo antes de cada guardado, y rechaza directamente las bases de datos dañadas en lugar de cargar datos parciales.
- **Un programa independiente lo confirma.** Cada versión debe superar una prueba de control en la que KeePassXC — una app de KeePass muy usada que no comparte código con KeeForge — abre las bases de datos escritas por KeeForge, descifra las contraseñas y confirma que los archivos adjuntos coinciden bit a bit. Las bases de datos creadas por otro software de KeePass deben, a su vez, abrirse en KeeForge y seguir siendo legibles en otros programas después de que KeeForge las guarde.

Para quien tenga curiosidad técnica, la batería de pruebas está descrita en [`KeeForgeTests/README.md`](KeeForgeTests/README.md) y la prueba de control previa a cada versión en [`ci_scripts/README.md`](ci_scripts/README.md) (ambas en inglés).

## Mapa del proyecto

```text
KeeForge/
├── App/              # Punto de entrada de la app, shell raíz adaptativo, ciclo de vida de la escena
├── Extensions/       # Ayudantes de compatibilidad entre plataformas compartidos
├── Models/           # Analizador/escritor de KDBX, criptografía, borrador de edición, TOTP, llaves de acceso
├── Resources/        # Catálogos de cadenas y catálogos de recursos
├── Services/         # Persistencia, sincronización en la nube, Llavero, marcadores, archivos adjuntos, ayudantes de autorrelleno
├── ViewModels/       # Lista de bases de datos, desbloqueo, guardado, búsqueda, orden, estado de TOTP
├── Views/            # Pantallas de SwiftUI, editor, ajustes, propina, controles reutilizables
AutoFillExtension/    # Proveedor de credenciales de autorrelleno, autenticación con llave de acceso, creación de credenciales
KeeForgeMac/          # App nativa experimental para macOS (sin publicar, en pausa)
KeeForgeMacUITests/   # Cobertura de XCUITest para la app de macOS
KeeForgeTests/        # Pruebas unitarias
KeeForgeUITests/      # Cobertura de XCUITest
TestFixtures/         # Bases de datos .kdbx de ejemplo y archivos de clave
Vendor/               # Paquete Swift KeeForgeTwofish incluido en el repositorio
ci_scripts/           # Scripts de arranque de Xcode Cloud y de la prueba de control de publicación
scripts/              # Herramientas de desarrollo local
```

## Documentación

- [`CHANGELOG.md`](CHANGELOG.md) – historial de versiones
- [`ROADMAP.md`](ROADMAP.md) – trabajo de producto planificado y prioridades abiertas
- [`AGENTS.md`](AGENTS.md) – contexto para agentes de codificación
- [`KeeForge/README.md`](KeeForge/README.md) – mapa de la arquitectura de los targets de la app
- [`AutoFillExtension/README.md`](AutoFillExtension/README.md) – restricciones de la extensión y notas sobre el código compartido
- [`SECURITY.md`](SECURITY.md) – política de divulgación de vulnerabilidades
- [`docs/`](docs/) – especificaciones de implementación, auditorías y documentos de diseño más extensos

Aparte de este README y [`CONTRIBUTING.es.md`](CONTRIBUTING.es.md), la documentación para desarrolladores se mantiene solo en inglés.

## Soporte

- App Store: [KeeForge en la App Store](https://apps.apple.com/us/app/keeforge/id6759309295)
- Correo: [support@keeforge.com](mailto:support@keeforge.com)
- Incidencias: [GitHub Issues](https://github.com/KeeForge/KeeForge/issues)

## Contribuir

Consulte [`CONTRIBUTING.es.md`](CONTRIBUTING.es.md) para conocer los requisitos de compilación, cómo compilar desde el código fuente, el flujo de trabajo de pull requests, el requisito de firma del Developer Certificate of Origin, y los términos de licencia. Empiece por [`AGENTS.md`](AGENTS.md) y luego abra el `README.md` local de la carpeta más cercana al código que vaya a modificar.

## Licencia

KeeForge tiene licencia GPLv3. Consulte [`LICENSE`](LICENSE) para más información.
