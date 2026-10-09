# MEGAHNET — análisis del flujo y base para migrar de lenguaje

Documento de análisis. **No cambia código.** Todo lo que aquí se afirma sale de leer
el repositorio `megahnet-v2` (rama `main`, commit `c0e108c`). Donde algo se dedujo
de los nombres de los métodos y no de leer su cuerpo, se marca como *(deducido)*.

Es genérico a propósito: no contiene nombres de clientes, RUC, IP ni datos de
ninguna instalación. Se puede compartir tal cual.

---

## 1. Qué es

Sistema de **facturación y gestión para un proveedor de internet (ISP)**, pensado
para correr una instancia por empresa (multi-instalación, no multi-inquilino en una
sola base). El ciclo de negocio que cubre:

```
 cliente ──► contrato (plan de internet, IP, zona, repetidora)
                │
                ▼  cada mes
        cobro automático ──► crédito (deuda) + factura electrónica
                │                         │
                │                         ▼
                │              firma + envío al SRI (Ecuador)
                │                         │
                ▼                         ▼
          abonos / pagos          correo (RIDE+XML) · WhatsApp
                │
                ▼
         corte / reconexión en el MikroTik
```

## 2. Arquitectura actual

| Capa | Qué hay | Tamaño |
|---|---|---|
| Navegador | jQuery, jQuery UI, Bootstrap, DataTables, SweetAlert2, CKEditor, navegación tipo pjax propia | 44 archivos / **10.741** líneas de JS propio |
| Enrutador | `index.php`: `?url=controlador/método/parámetro`, un solo punto de entrada | ~100 líneas |
| Controladores | 31, un método público = una ruta | **15.785** líneas |
| Modelos | 29, SQL escrito a mano sobre PDO | **4.424** líneas |
| Vistas | 106 plantillas PHP con HTML | **18.528** líneas |
| Tareas programadas | 7 temporizadores systemd + scripts PHP | 1.460 líneas |
| Base de datos | MariaDB 11.8, 39 tablas, 26 claves foráneas, **0** triggers/vistas/procedimientos | — |
| Servicio aparte | `services/whatsapp-api`: **NestJS + Baileys (TypeScript)**, ya está en otro lenguaje | — |
| Motor de facturación | `facturaelectronica/`: XML, firma, SOAP, RIDE en PDF | **fuera del repo** (§6.1) |

Es un MVC casero de unas 100 líneas de "framework" (`Controller`, `Query`, `Views`,
`Autoload`). **Casi toda la lógica de negocio vive en los controladores, en los
`cron` y en el JavaScript**, no en los modelos: los modelos son sobre todo
consultas.

Cada controlador hace `session_start()` en su constructor y exige
`$_SESSION['id_usuario']`. La autorización por rol es mínima: solo `Admin`
distingue `rol` 1 / `rol` 2.

### Dos personalidades en el mismo controlador

Los 31 controladores devuelven a la vez **HTML** (86 llamadas a `getView`) y **JSON**
(495 `json_encode`). El JavaScript consulta del orden de **200+ pares
controlador/método** (conteo aproximado). Es una API de hecho, **sin contrato
escrito**: cualquier migración tiene que empezar por documentarla.

## 3. Flujos de negocio

### 3.1 Cobro mensual automático *(leído completo)*

Temporizador `facturacion-mensual`, día 1 a las 02:00 (`flock` + un cierre propio
en `storage/`). Luego, a las 02:30, `facturacion-ordenventa` hace lo mismo para
los contratos **sin** factura electrónica.

```
getContratosFacturar(mes)            contratos con:
  mes_facturar.<mes> = 0               · el flag del mes sin marcar
  estado = 1, factura = 1              · activos y con factura electrónica
  y sin crédito en el mes en curso     · (guarda anti-duplicado)
        │
        ▼  por cada contrato
  1. cabecera electrónica      (estado 2 = "pendiente del SRI")
  2. detalle por producto      (precio sin IVA, IVA, código)
  3. descuenta stock + movimiento de inventario
  4. crédito                   (la deuda del cliente)
  5. mes_facturar.<mes> = 1    y el del mes anterior vuelve a 0
```

Puntos que importan para migrar:

- **No hay transacción.** Los cinco pasos son escrituras sueltas. Si el paso 2
  falla, queda una cabecera sin líneas y el ciclo sigue con el siguiente
  contrato.
- El número de comprobante es `MAX(id) + 1` (condición de carrera) y además el
  detalle apunta por clave foránea al `id` de la cabecera, no a su número.
- `mes_facturar` guarda el estado de facturación en **12 columnas** (una por mes)
  y el cron *rota* los flags. Es la causa de que se necesitara una guarda extra
  contra la doble facturación.
- `contratos.productos` es **JSON dentro de una columna**.
- El precio por línea se recalcula en el cron, y el crédito se crea con
  `contratos.total`: si ambos no coinciden, nada lo detecta.
- `$limite = 25` está declarado "para procesar en bloques" y **nunca se usa**.

### 3.2 Envío al SRI *(deducido de los cron y de `ServicesSri.php`)*

```
cron sri-facturas   (cada 10 min)   toma cabeceras pendientes con detalle
   └─► enviarXML::envioXML()        genera el XML y lo firma
   └─► validacionComprobante        SOAP: recepción
   └─► autorizacionComprobante      SOAP: autorización
   └─► tabla respuesta_sri + estado_proceso de la cabecera
cron sri-reintentos (cada 10 min)   rechazadas / sin respuesta
cron envio-correo   (cada 10 min)   RIDE (PDF) + XML al cliente, y WhatsApp
```

Estados de `datos_cabecera_electronica.estado_proceso` que usa el código:
`0` pendiente, `1` autorizada, `2` reintentable. **Los significados no están
documentados en el esquema**: hay que sacarlos del código de cada cron. Ojo: en
v2 el `1` se escribe al enviar **sin mirar qué contestó el SRI**, de modo que
"autorizada" significa "se intentó" (ver 6.2).

### 3.3 Cobro manual y pagos

- **`Creditos`**: lista deudas, `registrarAbono`, `registrarAbonoVarios`,
  `eliminarAbono`, `notificarCliente`.
- **`Automaticas::facturarContrato`**: el botón de "facturar contrato" desde el
  panel; repite el flujo 3.1 para un contrato a demanda. Es una **segunda
  implementación** de la misma regla de negocio.
- **`Ventas::registrarVenta`**: punto de venta / factura manual de productos.
  Tercera implementación del "crear cabecera + detalle".
- Cada una de las tres escribe cabecera y detalle por su cuenta.

### 3.4 Otros documentos tributarios

`notaCredito` y `Retenciones` repiten el patrón (cabecera + detalle + envío al
SRI + correo) sobre sus propias tablas.

### 3.5 Contratos y red *(deducido de los nombres de métodos)*

`Contratos` (23 métodos) gestiona alta, edición, suspensión, reactivación,
importación desde Excel, zonas/repetidoras y la **generación del contrato en
documento** (Word → PDF con LibreOffice). Habla con el MikroTik mediante la API
RouterOS (`routeros_api.class.php`, 438 líneas, protocolo binario propio) en
`Contratos`, `mikrotiks` y `cron_verificar_mikrotiks`.

### 3.6 Administración

`Admin` (44 métodos, 1.788 líneas) mezcla: respaldos y restauración de la base,
borrado de datos, módulos visibles, plantillas de mensajes, roles, servicios
externos y **el actualizador de la propia aplicación** (script del sistema
`megahnet-update` que hace `git fetch` y vuelve a ejecutar el instalador, con modo
mantenimiento por archivo-bandera).

## 4. Modelo de datos

Núcleo (las 39 tablas tienen además catálogos: categorías, medidas, zonas,
sucursales, proveedores, usuarios, grupos de trabajo…):

```
clientes ─┬─< contratos ──1:1── mes_facturar (12 columnas, una por mes)
          │        └──────< creditos >──┬── datos_cabecera_electronica ──< detalle_factura_electronica
          │                    │        ├── orden_venta                  └── respuesta_sri (por clave de acceso)
          │                    │        └── ventas
          │                    └──< abonos
          ├─< orden_venta        cajas ─< gastos       productos >─ inventario (kardex)
          └─< nota_credito_cabecera / retencion
```

Rarezas relevantes:

- `creditos` puede nacer de **tres** orígenes (venta, factura electrónica, orden
  de venta) y tiene una columna para cada uno; cada fila usa solo una y deja las
  otras dos vacías.
- `creditos.estado` y `datos_cabecera_electronica.estado`/`estado_proceso` son
  enteros con significados distintos y sin tabla de referencia.
- `detalle_factura_electronica.orden_no` referencia `cabecera.id`, no
  `cabecera.orden_no`.
- Hay estado **fuera de la base**: `storage/modulos.json`, `storage/plantillas.json`,
  los PDF/XML en disco y el archivo-bandera de mantenimiento.
- Casi no hay lógica en la base (sin triggers, vistas ni procedimientos): es una
  ventaja, la migración no arrastra lógica escondida en SQL.

## 5. Dependencias externas

| Qué | Para qué | Dónde se usa |
|---|---|---|
| SRI (SOAP) | recepción y autorización de comprobantes | motor `facturaelectronica/` |
| OpenSSL con proveedor *legacy* | abrir el certificado `.p12` (RC2-40/MD5) | `Ventas`, `Admin` (por línea de comandos) |
| MikroTik RouterOS API | cortes, reconexión, colas | `Contratos`, `mikrotiks`, cron |
| SMTP (PHPMailer) | correo de facturas, alertas, respaldos | 15 archivos |
| WhatsApp | avisos y confirmaciones | servicio NestJS propio, 11 archivos lo invocan |
| Payphone | pagos en línea | `Payphone` (3 métodos) |
| LibreOffice | convertir el contrato Word a PDF | `Contratos` |
| `mysqldump` / `mysql` / `git` / `php` CLI | respaldos, actualizador, trabajos en segundo plano | `Admin`, `Helpers`, `OrdenVenta` |
| Bibliotecas PHP | dompdf, escpos-php (impresora térmica), generador de códigos de barras, PhpSpreadsheet, PhpWord, PHPMailer | `composer.json` |

## 6. Qué conviene saber ANTES de migrar

### 6.1 El motor de facturación electrónica no está en el repositorio

`facturaelectronica/` está en `.gitignore`. `config/ServicesSri.php` hace
`include_once` de seis archivos de esa carpeta (`lib2/config.php`,
`lib2/functions.php`, `acciones.php`, `envio_xml.php`,
`src/validacionComprobante.php`, `src/autorizacionComprobante.php`). Ahí vive la
parte **más delicada** del sistema —XML, firma, SOAP, RIDE— y existe solo en los
servidores, mezclada con la firma electrónica y con archivos generados.

Consecuencias directas:

1. **El entorno local no puede emitir facturas**: arranca, pero cualquier envío al
   SRI falla por clases inexistentes.
2. No hay forma de revisar ni probar ese código desde Git.
3. Es el primer trabajo de una migración: traerlo, separar el código de la firma y
   de los archivos generados, y versionarlo.

### 6.2 `megahnet-v2` está desfasado respecto a lo que corre en producción

Faltan tres commits que sí están desplegados en la instalación de referencia:
la guarda anti-doble-facturación por mes, la corrección del estado de las
facturas devueltas por el SRI, y la transacción cabecera+detalle con recorte de
campos al límite del SRI (más una migración y dos pruebas). Migrar desde v2 sin
portarlos **copiaría los errores ya corregidos**.

### 6.3 El 40 % del SQL pega variables PHP dentro del texto

De 560 sentencias SQL: **231 (41 %) parametrizadas**, 103 fijas, 11 mixtas y
**215 (38 %) con variables interpoladas**. Concentradas en `ClientesModel`
(37 de 46), `ContratosModel` (22 de 48), `AutomaticasModel` (19 de 40) y
`CajasModel` (19 de 24).

No todas son explotables (algunas interpolan el nombre de una columna de mes que
sale de un arreglo interno), pero **cada una hay que clasificarla**. Al reescribir
se resuelve solo si el acceso a datos nuevo no permite concatenar.

### 6.4 Reglas de negocio duplicadas

Crear una factura está implementado al menos tres veces (cron mensual,
`facturarContrato`, `registrarVenta`) y un cuarto camino para órdenes de venta.
Cada copia ha divergido: ese es el origen de varios errores recientes. En la
migración conviene **una sola función de dominio** y los cuatro caminos como
llamadores finos.

### 6.5 Seguridad que se resuelve mejor al reescribir

- La contraseña de la firma electrónica se guarda en base **solo en base64**
  (reversible, no cifrada).
- Autorización por rol casi inexistente fuera de `Admin`.
- Ejecución de comandos del sistema desde controladores web (`proc_open`,
  `shell_exec`) para respaldos, actualización, `openssl` y LibreOffice.

### 6.6 Comentarios que no coinciden con el código

Los cron dicen "compatible PHP 7.4" aunque el sistema corre en 8.4; el cron de
reintentos dice "máx 2" y el código permite 25. `Helpers.php` define `moduloActivo` dos veces
(con lógicas distintas); como ambas van protegidas por `function_exists`, solo vale
la primera y la segunda es código muerto. Señal de que **no se puede confiar en los
comentarios**: la fuente de verdad es el comportamiento.

### 6.7 Qué ya juega a favor

- Casi nada de lógica en la base: sin triggers, vistas ni procedimientos.
- El servicio de WhatsApp **ya es un servicio aparte en TypeScript**: se queda
  como está.
- Hay pruebas de comportamiento que se pueden convertir en una *red de seguridad*
  (en v2: 2; en el repositorio base: 5), y el instalador tiene su propio banco de pruebas.
- Un entorno local reproducible (`docker/`), aunque sin el motor del SRI.

## 7. Dificultad por módulo

| Dificultad | Módulos |
|---|---|
| **Baja** | catálogos (categorías, medidas, zonas, sucursales, repetidoras, proveedores, grupos), usuarios, cotizaciones |
| **Media** | clientes, productos e inventario, cajas y gastos, ventas, créditos y abonos, reportes Excel/PDF, órdenes de venta |
| **Alta** | **cobro mensual** (idempotencia y dinero), **SRI** (XML + firma + SOAP + RIDE + certificado heredado), **MikroTik** (protocolo binario propio), contratos en documento, actualizador y respaldos |
| **No tocar** | servicio de WhatsApp (ya está en TypeScript y funciona) |

## 8. Decisiones abiertas

Ninguna de estas la decido yo; condicionan todo lo demás.

1. **Lenguaje y plataforma de destino.** Lo que más pesa en la elección no es el
   CRUD sino tres cosas: firma XML con certificado heredado, SOAP del SRI y la
   API binaria de RouterOS. Conviene elegir viendo qué bibliotecas maduras hay
   para esas tres.
2. **Estrategia**: reescritura completa, o por módulos conviviendo con PHP sobre
   la **misma base** (el servicio de WhatsApp ya demuestra que conviven).
3. **Frontend**: conservar el JavaScript actual contra una API nueva, o
   rehacerlo.
4. **Qué instalaciones migran primero** y si la base se conserva tal cual o se
   rediseña (`mes_facturar` en 12 columnas, los tres orígenes de `creditos`).
5. Si se **portan antes** los tres commits pendientes a `megahnet-v2`.

## 9. Cómo se verificó

Lectura directa del código de `megahnet-v2`: enrutador, `Controller`, login,
cron de facturación mensual completo, `ServicesSri.php`, esquema SQL, instalador
de temporizadores, `Dockerfile`. Las cifras de SQL salen de un script que
clasifica cada sentencia (parametrizada / fija / mixta / interpolada); es una
heurística: sirve para dimensionar, no para auditar.

**No se pudo verificar** el contenido de `facturaelectronica/` ni el volumen real
de datos, porque requieren acceso al servidor (fuera de alcance en este trabajo
local).
