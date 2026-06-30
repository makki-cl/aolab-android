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
