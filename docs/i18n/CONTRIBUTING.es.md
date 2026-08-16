# Contribuir a KeeForge

<a href="../../CONTRIBUTING.md">English</a> | <a href="CONTRIBUTING.de.md">Deutsch</a> | <a href="CONTRIBUTING.fr.md">Français</a> | Español | <a href="CONTRIBUTING.zh-Hans.md">简体中文</a> | <a href="CONTRIBUTING.zh-Hant.md">繁體中文</a>

Gracias por ayudar a mejorar KeeForge.

## Antes de empezar

- Para un cambio importante, abra primero una incidencia para que el alcance y el enfoque puedan discutirse.
- Lea [`AGENTS.md`](../../AGENTS.md) y después el `README.md` local de la carpeta más cercana al código que planea cambiar.
- Mantenga los cambios acotados. Los cambios sensibles en materia de seguridad en el analizador, el escritor, la criptografía, el manejo de secretos y las rutas de guardado requieren pruebas específicas.

## Requisitos

- iOS 18+
- Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Swift 6 con concurrencia estricta
- Dependencias de Swift Package: [Argon2Swift](https://github.com/tmthecoder/Argon2Swift), [SwiftyDropbox](https://github.com/dropbox/SwiftyDropbox), [Microsoft Authentication Library](https://github.com/AzureAD/microsoft-authentication-library-for-objc), [swift-psl](https://github.com/ameshkov/swift-psl), y el paquete [KeeForgeTwofish](../../Vendor/KeeForgeTwofish) incluido en el repositorio

## Compilar desde el código fuente

```bash
cp BuildConfig.local.example.xcconfig BuildConfig.local.xcconfig
# Complete DROPBOX_APP_KEY y ONEDRIVE_CLIENT_ID para compilaciones con proveedores habilitados.
xcodegen generate
open KeeForge.xcodeproj
```

Seleccione un simulador o dispositivo con iOS 18+, y luego compile y ejecute el esquema `KeeForge`.

Para la verificación desde la línea de comandos, prefiera el subconjunto de pruebas más pequeño y relevante:

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/DatabaseViewModelTests -quiet
```

## Flujo de trabajo de desarrollo

1. Haga un fork del repositorio y cree una rama temática a partir de `main`.
2. Haga el cambio coherente más pequeño que resuelva el problema.
3. Añada o actualice pruebas, usando el target de pruebas más pequeño relevante y `-only-testing:`.
4. Añada notas de funciones y correcciones bajo `## Unreleased` en [`CHANGELOG.md`](../../CHANGELOG.md).
5. Abra una pull request describiendo el cambio de comportamiento y cómo se verificó.

Un mantenedor revisa cada pull request antes de fusionarla. KeeForge usa squash merges, así que mantenga la pull request acotada y déle un título claro.

### Qué rama utilizar como destino

Use `main` como destino por defecto para todo.

Cuando se está preparando una versión, también existe una rama `release/{major}.{minor}` activa
en pruebas en TestFlight. Diríjase a esa rama solo si un mantenedor se lo pide: está reservada
para correcciones de errores encontrados en el candidato de versión, y cada commit que llega ahí
obliga a una nueva compilación y reinicia la ventana de pruebas. Los mantenedores trasladan esas
correcciones a `main` por separado; no abra el mismo cambio contra ambas ramas.

Dos comprobaciones de estado deben pasar antes de que una pull request pueda fusionarse:

- **unit-tests** — ejecuta la batería de pruebas unitarias `KeeForgeTests` en un simulador de iOS mediante GitHub Actions.
- **DCO** — verifica que cada commit esté firmado (vea más abajo).

## Developer Certificate of Origin

KeeForge usa el [Developer Certificate of Origin 1.1](https://developercertificate.org/) (DCO). Al firmar un commit, certifica que tiene el derecho de enviar la contribución bajo la licencia de código abierto de este repositorio.

Firme cada commit con la opción `-s` de Git:

```bash
git commit -s -m "fix: describe the change"
```

Esto añade al mensaje del commit un trailer como este:

```text
Signed-off-by: Su nombre <su.email@example.com>
```

La firma es una certificación, no una firma criptográfica; `git commit -s` es distinto de `git commit -S`.

Si ya existen commits sin firmar, añádala mientras hace rebase sobre la rama `main` actual:

```bash
git fetch origin
git rebase --signoff origin/main
```

Como el rebase reescribe el historial de commits, actualice después la rama del contribuidor con `git push --force-with-lease` cuando sea necesario.

## Licencia

Al enviar una contribución, usted acepta que se licencie bajo los mismos términos de la GNU GPL que cubren este repositorio. También declara que usted creó la contribución o que, de otro modo, tiene el derecho de enviarla bajo esos términos.

No envíe código copiado de una fuente incompatible. Señale en la pull request cualquier código de terceros, recursos generados, u otro material con requisitos de licencia o atribución independientes.

---

El resto de la documentación para desarrolladores — [`AGENTS.md`](../../AGENTS.md) y los `README.md` locales de cada carpeta — se mantiene solo en inglés. En caso de duda, prevalece la [versión en inglés de este documento](../../CONTRIBUTING.md).
