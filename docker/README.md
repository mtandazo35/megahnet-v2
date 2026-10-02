# Entorno local con Docker

Levanta MEGAHNET en tu equipo para programar y probar. **No tiene ninguna conexion con
produccion** y no puede alcanzarla: todo vive en contenedores de esta maquina.

## Requisito

**Docker Desktop**. Si no lo tienes, en PowerShell como administrador:

```powershell
winget install Docker.DockerDesktop
```

Despues hay que **reiniciar sesion** (o el equipo) y abrir Docker Desktop una vez, para
que arranque su servicio.

## Arrancar

```bash
cd docker
docker compose up -d --build
```

La primera vez tarda varios minutos: construye la imagen de PHP con sus extensiones,
instala las dependencias de composer y prepara la base de datos.

Despues: **http://localhost:8080**

## Parar y volver

```bash
docker compose stop     # parar sin perder nada
docker compose up -d    # volver a levantar
docker compose down -v  # BORRAR TAMBIEN LA BASE DE DATOS (empezar de cero)
```

## Que levanta

| Contenedor | Que es | Donde se alcanza |
|---|---|---|
| `megahnet-web` | PHP 8.4 + Apache, con las mismas extensiones que instala el servidor | http://localhost:8080 |
| `megahnet-db` | MariaDB 11.8, la misma version que produccion | `127.0.0.1:3307` (solo desde esta maquina) |

El codigo **se monta en vivo** desde el repositorio: lo que edites en VS Code se ve al
recargar el navegador, sin reconstruir nada.

## Como se prepara la base

La primera vez que arranca, y solo esa vez:

1. `10-esquema.sh` carga `db/schema.sql`.
2. `20-migraciones.sh` aplica `db/migrations/` **con la libreria del instalador nuevo**
   (`installer/lib/migraciones.sh`).

Ese segundo paso no es comodidad: esa libreria solo se habia probado contra un cliente
de base de datos simulado. Aqui se ejecuta contra MariaDB de verdad cada vez que alguien
levanta el entorno desde cero. Si algun dia deja de funcionar, se sabra aqui y no en
produccion.

Si una migracion falla, **el arranque se detiene a proposito**: una base a medias es peor
que una base vacia, y es justo lo que el instalador actual deja pasar con su `|| true`.

## Datos

Arranca con la base **vacia**: solo el esquema. Para trabajar con datos de verdad, usa
una copia anonimizada:

```bash
bash scripts/anonimizar.sh respaldo-produccion.sql.gz copia-lab.sql.gz
gzip -dc copia-lab.sql.gz | docker exec -i megahnet-db mariadb -umegahnet -pmegahnet sistema
```

**Nunca cargues aqui un respaldo sin anonimizar**: son datos de clientes reales.

## Ajustes

Crea `docker/.env` si quieres cambiar los valores por defecto:

```
PUERTO_WEB=8080
PUERTO_DB=3307
DB_NAME=sistema
DB_USER=megahnet
DB_PASSWORD=megahnet
DB_ROOT_PASSWORD=raiz-local
```

Son credenciales de juguete para un entorno que solo escucha en tu maquina. Aun asi, ese
archivo no se sube: esta en `.gitignore`.

## Lo que este entorno NO prueba

En produccion PHP **no** corre en contenedor: va con Apache sobre Debian. Aqui se prueba
la aplicacion, no la maquina. Quedan fuera los permisos de archivos, los temporizadores
de systemd, el arranque del sistema y el instalador — que son, precisamente, donde estan
los fallos que nos trajeron hasta aqui. Para eso hace falta una Debian de verdad.
