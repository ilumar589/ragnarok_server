# ragnarok_pg — libpq library files

Place the PostgreSQL client library files here for linking:

## Windows

1. Install PostgreSQL from https://www.postgresql.org/download/windows/
   (full install or client-only)

2. Copy from your PostgreSQL install directory:
   ```
   lib\libpq.lib  →  ragnarok_pg\lib\libpq.lib
   ```

3. Ensure the following DLLs are on your PATH or next to the executable:
   ```
   bin\libpq.dll
   bin\libssl-3-x64.dll
   bin\libcrypto-3-x64.dll
   bin\libintl-9.dll
   bin\libiconv-2.dll
   ```

   Typical install path: `C:\Program Files\PostgreSQL\16\`

### Alternative: vcpkg

```powershell
vcpkg install libpq:x64-windows
# Copy libpq.lib from vcpkg installed directory
```

## Linux

No files needed here — `libpq-dev` provides the system library:

```sh
# Debian/Ubuntu
sudo apt install libpq-dev

# Fedora/RHEL
sudo dnf install libpq-devel
```

The `system:pq` foreign import handles linking automatically.
