# Etapas de revision

Una etapa se cierra cuando su comprobacion pasa **y** se puede volver a ejecutar cuando
se quiera. Lo que se arregle aqui se lleva al repositorio principal (`../megahnet`) con el
metodo de siempre: punto de retorno, prueba que falle con el codigo anterior, revision
adversarial y despliegue por etapas.

---

## Etapa 1 — Instalacion y arranque

Que el sistema se levante entero en una Debian limpia, **sin pasos manuales**.

Lo que ya sabemos que esta mal:

- **Los temporizadores no los instala nadie.** `install.sh` no crea ninguna unidad de
  systemd; los de produccion se pusieron a mano, maquina por maquina. Por eso el 1 de
  octubre rutanet no facturo las ordenes de venta: a esa maquina le faltaba el suyo, y
  nadie se entero.
- `install.sh` hace demasiadas cosas en un solo archivo.
- Las migraciones terminan en `|| true`: si una falla, la instalacion sigue.
- Usuario administrador por defecto con contrasena conocida.
- Modifica el OpenSSL **global** del sistema para las firmas del SRI.
- Siete enlaces simbolicos para tapar nombres de archivo heredados de Windows.

Comprobacion de la etapa: en una Debian recien instalada, un solo comando deja el sistema
respondiendo, con **todos** sus temporizadores activos y listados, y la verificacion
final en verde.

---

## Etapa 2 — Clientes y contratos

Altas, planes, meses a facturar.

- 617 clientes sin correo utilizable (499 activos), con erratas tipo `klopezb16@gmailcom`
  o un RUC metido en el campo correo. No hay validacion al guardar.
- Contratos sin fila en `mes_facturar` serian invisibles para la facturacion: hay que
  comprobar si existen.

Comprobacion: dar de alta un cliente y su contrato, y que aparezca en la facturacion del
mes siguiente sin tocar la base a mano.

---

## Etapa 3 — Facturacion automatica

Los dos crons mensuales, que no se cubren entre si:

- `cron_facturacion_automaticas.php` factura los contratos con factura electronica.
- `cron_facturacion_ordenventa.php` factura los de orden de venta.

Lo que ya sabemos:

- En el primero, `$limite = 25` esta declarado, comentado en rojo **y no se usa**: una
  sola ejecucion intenta facturar los cientos de contratos de golpe.
- Si un producto del contrato ya no esta en el catalogo, ese contrato falla entero y el
  error acaba en un archivo que nadie abre.
- Nadie se entera de un mes sin facturar: un fallo total y un mes tranquilo se ven igual
  desde el panel (un cero).

Comprobacion: con la copia anonimizada, facturar el mes completo, cortar el proceso a
proposito a mitad, y comprobar que al relanzarlo continua sin duplicar ni saltarse nada.

---

## Etapa 4 — Factura electronica / SRI

- El generador real es `facturaelectronica/envio_xml.php`; las tres copias de
  `FacturaSRI.php` son codigo muerto.
- El RIDE tiene una lista blanca: un campo nuevo no sale en el PDF si no se anade ahi.
- La clave de acceso depende del ambiente y del punto de emision.

Para probar aqui hacen falta certificado de pruebas y ambiente de certificacion del SRI.
**Esta etapa no se toca hasta tenerlos**: es la parte con consecuencias legales.

---

## Etapa 5 — Cobros

Creditos, abonos, caja, comprobantes.

- Resuelto: el abono parcial fallaba cuando el producto ya no estaba en el catalogo.
- Pendiente: la validacion del comprobante en el modal de abonos se rompe con codigos
  que llevan letras y pega el texto directo en la consulta.

Comprobacion: cobrar total y parcial, con y sin comprobante repetido, y que la caja cuadre.

---

## Etapa 6 — Notificaciones

- La cola de correo estuvo **29 dias sin enviar nada**: el lote se llenaba de clientes sin
  correo y, como no se marcaban, volvian cada 10 minutos para siempre.
- No existe ningun rastro por factura: no se puede demostrar si a un cliente se le envio.
- El cron del SRI muere al intentar enviar porque le falta cargar una funcion.

El arreglo ya esta escrito y revisado en el repositorio principal; aqui se prueba de
verdad: destaponar, un ciclo controlado, y leer a quien se le envio.

---

## Etapa 7 — Red / Mikrotik

Suspensiones, reconexiones, cambios de plan. Sin revisar todavia.

---

## Etapa 8 — Panel y actualizador

Version, actualizacion desde la web, respaldo y vuelta atras. Funciona; queda endurecer
el salto de la web a root y que el codigo deje de ser propiedad del servidor web.
