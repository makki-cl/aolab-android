# Aolab Android

App móvil **offline-first** (Flutter) para capturar formularios sin conexión y
**sincronizarlos** con el backend [Aolab](https://github.com/makki-cl/aolab) cuando
hay red. Pensada para uso en terreno: se guarda todo localmente y se reconcilia con
el servidor en segundo plano.

## Arquitectura

- **Almacenamiento local (fuente de verdad):** SQLite vía `sqflite`. La UI siempre
  lee/escribe local; la app funciona 100% sin conexión.
- **Sincronización:** un `SyncService` hace **push** de los registros con cambios
  pendientes (`dirty`) y **pull** de los cambios del servidor por **cursor**
  (`serverVersion`), aplicando también los borrados (tombstones).
- **Identidad offline:** cada registro usa un **GUID generado en el cliente**, así se
  puede crear sin conexión sin colisiones.
- **Auth:** login contra `/api/auth/login`, el **JWT** se guarda en
  `flutter_secure_storage` y se adjunta a cada request.

```
lib/
  config.dart                 URL base del backend (--dart-define configurable)
  main.dart                   Arranque + providers + ruteo login/home
  data/
    form_entry.dart           Modelo + mapeo a DTO de la API y a fila SQLite
    app_database.dart         SQLite: tabla form_entries + cursor de sync
  services/
    api_client.dart           Dio + inyección del JWT
    auth_service.dart         Login, token seguro, estado de sesión
    sync_service.dart         push/pull offline-first
  ui/
    login_screen.dart
    form_list_screen.dart     Lista + estado de sync + pendientes
    form_edit_screen.dart     Alta/edición/borrado (guarda offline)
```

## Requisitos

- Flutter SDK (stable) y Android SDK **en tu máquina de desarrollo**.
  > La VM de backend NO compila Android (poca RAM); aquí solo vive el código.

## Puesta en marcha

```bash
flutter pub get

# Generar las carpetas de plataforma si clonaste solo el código fuente:
#   flutter create --org cl.makki --project-name aolab_android .

# Correr apuntando al backend (ejemplo, backend en una VM de test):
flutter run --dart-define=AOLAB_API_BASE_URL=http://<IP_DE_LA_VM>:5080
```

## Pruebas

```bash
flutter analyze
flutter test        # no necesita dispositivo ni emulador
```

- `test/llaves_ajenas_test.dart`: la copia local (SQLite) de la auditoría conserva las llaves que
  la app no conoce (cabecera, documento, sistema, respuesta, punto y evidencia), y el push NO las
  manda: la copia de la app puede estar vieja y el servidor conserva lo que no viene.
- `test/maestro_test.dart`: lee el maestro nuevo (centros con el modelo con equipos), el de un
  servidor anterior y uno de un servidor más nuevo; agrupa los puntos sin perder ninguno. Usa JSON
  real del servidor en `test/fixtures/`.
- `test/niveles_test.dart`: la posición por nivel de los grupos efímeros con los mismos casos de la
  web (código del miembro, posición obligatoria, etiqueta, reutilización en la evaluación).
- `test/modelo_hoy_test.dart`, `test/editor_test.dart`: puntos de nivel, varias muestras y «+ Otro
  rack», nombres con el tipo debajo, sistemas por tipo como la lista lateral del editor y las
  evaluaciones compartidas (se finalizan en la web).
- `test/sesion_test.dart`, `test/pantallas_test.dart`: entrar con clave, Google o Microsoft (los
  botones que ofrece el servidor), errores en español, sesión vencida y cambio de usuario.

Prueba de contrato contra un servidor **local** (una copia; nunca prod ni TEST). No corre en el CI:

```bash
AOLAB_CONTRATO_URL=http://127.0.0.1:<puerto> AOLAB_CONTRATO_CORREO=… AOLAB_CONTRATO_CLAVE=… \
  flutter test integration_local/contrato_test.dart
```

## Compilar (CI)

El repo no versiona la carpeta `android/`: el CI la genera con `flutter create` y la ajusta con
`bash tool/configurar_android.sh <applicationId> "<nombre>"` (paquete, permisos y el retorno de
«Entrar con Microsoft», que recibe AppAuth). Lo usan `build-apk.yml` (canal de prueba),
`verificar.yml` (compila un APK de depuración sin publicar) y el build de producción.

### ¿A qué URL apunta?
Configurable por `--dart-define=AOLAB_API_BASE_URL=...` (ver `lib/config.dart`).
- Emulador Android → backend en tu PC: `http://10.0.2.2:5080`
- Dispositivo físico / backend en VM: `http://<IP_o_dominio>:5080`

## Flujo offline → online

1. El usuario crea/edita formularios → se guardan en SQLite con `dirty = 1`.
2. Al recuperar conexión (o al tocar *sincronizar*), `SyncService`:
   - **push** de los `dirty` → el servidor responde su `serverVersion`.
   - **pull** desde el último cursor → baja cambios de otros dispositivos y borrados.
3. La lista muestra por registro si está sincronizado (✓) o pendiente (subida).

## Backend

Contrato y endpoints en el repo [makki-cl/aolab](https://github.com/makki-cl/aolab)
(`/api/auth/login`, `/api/sync/push`, `/api/sync/pull`).
