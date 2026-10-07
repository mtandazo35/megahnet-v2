<?php
/**
 * Prueba de que una factura DEVUELTA por el SRI no se queda varada.
 *
 * Usa el MODELO REAL (VentasModel) y la CONSULTA REAL de
 * cron/cron_sri_reintentos.php contra una base temporal. No toca produccion: la
 * base se indica con la variable de entorno DB_NAME, que tiene prioridad sobre
 * el .env (config/Config.php solo rellena lo que falta).
 *
 * El caso que motivo esta prueba (rutanet, 2026-10-02 y 2026-10-07):
 * `actualizarClaveAccesso` escribia siempre estado_proceso=1, sri_enviado=1 y
 * correo_enviado=1 SIN mirar la respuesta del SRI. Como el panel cuenta
 * estado_proceso=1 como "autorizada", tres facturas devueltas se veian emitidas;
 * y como cron_sri_facturas busca estado_proceso=0 y cron_sri_reintentos busca
 * estado_proceso=2, el valor 1 no caia en ninguno: los logs decian "Facturas a
 * reintentar: 0" mientras el cliente seguia sin factura.
 *
 * Uso (en el servidor, con la base temporal ya creada):
 *   DB_NAME=prueba_sri php tests/factura_sri_devuelta.test.php
 */

require_once dirname(__DIR__) . '/config/Config.php';
require_once dirname(__DIR__) . '/config/Helpers.php';
require_once dirname(__DIR__) . '/config/app/Autoload.php';

$ORDEN       = 99001; // comprobante de juguete, fuera del rango real
$ORDEN_VACIO = 99002; // comprobante sin lineas
$CLAVE       = '0710202699120087817900120010020000990010000990011';
$HOY         = date('Y-m-d');

$pdo = new PDO('mysql:host=' . HOSTT . ';dbname=' . DBNAME . ';charset=utf8mb4', USER, PASSWORD,
               [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);

echo 'base de pruebas: ' . DBNAME . PHP_EOL . PHP_EOL;

$limpiar = function () use ($pdo, $ORDEN, $ORDEN_VACIO, $CLAVE) {
    $pdo->exec("DELETE FROM detalle_factura_electronica WHERE orden_no IN ($ORDEN, $ORDEN_VACIO)");
    $pdo->exec("DELETE FROM datos_cabecera_electronica  WHERE orden_no IN ($ORDEN, $ORDEN_VACIO)");
    $pdo->exec("DELETE FROM respuesta_sri WHERE claveAcceso = " . $pdo->quote($CLAVE));
};

// --- La consulta REAL del cron de reintentos --------------------------------
$cron = file_get_contents(dirname(__DIR__) . '/cron/cron_sri_reintentos.php');
if (!preg_match('/\$sql\s*=\s*"(.*?)"\s*;/s', $cron, $m)) {
    fwrite(STDERR, "No se pudo extraer el SQL de cron_sri_reintentos.php\n");
    exit(2);
}
$sqlCron = $m[1];

$ok = 0; $mal = 0;
$comprobar = function ($condicion, $texto) use (&$ok, &$mal) {
    if ($condicion) { echo "  OK    $texto\n"; $ok++; }
    else            { echo "  FALLA $texto\n"; $mal++; }
};

$limpiar();

// --- Fixture: una factura tal como la dejaba el codigo viejo -----------------
// `detalle_factura_electronica.orden_no` apunta por clave foranea al `id` de la
// cabecera, asi que el id se fija a mano: en produccion id y orden_no coinciden.
$pdo->exec("INSERT INTO datos_cabecera_electronica
            (id, fecha, orden_no, cliente, ruc, totalfactura, claveacceso, metodo,
             id_usuario, id_cliente, estado, estado_proceso, sri_enviado, correo_enviado, intentos_sri)
            VALUES ($ORDEN, '$HOY', $ORDEN, 'CLIENTE PRUEBA', '0999999999001', 1414.50,
                    " . $pdo->quote($CLAVE) . ", 'CONTADO', 4, 9001, 1, 1, 1, 1, 0)");
$pdo->exec("INSERT INTO detalle_factura_electronica
            (orden_no, cantidad, item, precio_u, total, iva, codproducto, descuento, precio_pvp, por_descuento, id_producto)
            VALUES ($ORDEN, 1, 'SERVICIO DE PRUEBA', 100, 100, 15, 'INS', 0, 115, 0, 1)");

$modelo = new VentasModel();

// 1) El estado que dejaba el codigo viejo es invisible para el cron.
$varada = $pdo->query($sqlCron)->fetchAll(PDO::FETCH_ASSOC);
$comprobar(!in_array($ORDEN, array_column($varada, 'orden_no')),
    'con estado_proceso=1 el cron de reintentos NO la ve (es el bug que se arregla)');

// 2) Al guardar un "no autorizado", debe quedar reintentable.
$modelo->actualizarClaveAccesso($CLAVE, $ORDEN, false,
    "ARCHIVO NO CUMPLE ESTRUCTURA XML | The content of element 'detalles' is not complete.");

$fila = $pdo->query("SELECT estado_proceso, sri_enviado, correo_enviado, mensaje_sri
                     FROM datos_cabecera_electronica WHERE orden_no = $ORDEN")->fetch(PDO::FETCH_ASSOC);

$comprobar((int)$fila['estado_proceso'] === 2, 'el SRI no autoriza -> estado_proceso = 2 (reintentable)');
$comprobar((int)$fila['sri_enviado'] === 1,    'se conserva sri_enviado = 1 (el envio si ocurrio)');
$comprobar((int)$fila['correo_enviado'] === 0, 'no se marca el correo como enviado: no hay factura que mandar');
$comprobar(strpos((string)$fila['mensaje_sri'], 'ESTRUCTURA XML') !== false,
    'se guarda el motivo del SRI, visible desde el panel');

// 3) Ahora el cron REAL si la encuentra.
$reintentables = $pdo->query($sqlCron)->fetchAll(PDO::FETCH_ASSOC);
$comprobar(in_array($ORDEN, array_column($reintentables, 'orden_no')),
    'el cron de reintentos SI la toma (deja de estar varada)');

// 4) Un "autorizado" sigue comportandose como siempre.
$modelo->actualizarClaveAccesso($CLAVE, $ORDEN, true);
$fila = $pdo->query("SELECT estado_proceso, correo_enviado FROM datos_cabecera_electronica WHERE orden_no = $ORDEN")->fetch(PDO::FETCH_ASSOC);
$comprobar((int)$fila['estado_proceso'] === 1 && (int)$fila['correo_enviado'] === 1,
    'autorizada -> estado_proceso = 1 y correo pendiente de envio, como antes');

// 5) Llamada sin el parametro nuevo: comportamiento identico al de siempre.
$modelo->actualizarClaveAccesso($CLAVE, $ORDEN);
$fila = $pdo->query("SELECT estado_proceso FROM datos_cabecera_electronica WHERE orden_no = $ORDEN")->fetch(PDO::FETCH_ASSOC);
$comprobar((int)$fila['estado_proceso'] === 1,
    'sin el parametro nuevo no cambia nada (los demas llamadores siguen igual)');

// --- Una factura sin lineas se tiene que poder detectar ----------------------
$pdo->exec("INSERT INTO datos_cabecera_electronica
            (id, fecha, orden_no, cliente, ruc, totalfactura, metodo, id_usuario, id_cliente, estado)
            VALUES ($ORDEN_VACIO, '$HOY', $ORDEN_VACIO, 'CLIENTE PRUEBA', '0999999999001', 1414.50, 'CONTADO', 4, 9001, 1)");

$comprobar($modelo->contarDetalle($ORDEN_VACIO) === 0,
    'se detecta la factura sin lineas (la que el SRI devuelve con el error 35)');
$comprobar($modelo->contarDetalle($ORDEN) === 1,
    'una factura con lineas se cuenta bien');

// --- La columna aguanta lo que admite el SRI, y el recorte protege -----------
$col = $pdo->query("SHOW COLUMNS FROM detalle_factura_electronica LIKE 'item'")->fetch(PDO::FETCH_ASSOC);
preg_match('/\((\d+)\)/', $col['Type'], $mm);
$ancho = isset($mm[1]) ? (int)$mm[1] : 0;
$comprobar($ancho >= SRI_MAX_DESCRIPCION,
    "la columna item admite " . SRI_MAX_DESCRIPCION . " caracteres (migracion 010 aplicada; ahora: $ancho)");

$largo = str_repeat('DESCRIPCION MUY LARGA ', 40); // 880 caracteres
$insertado = $modelo->registrarDetalle($ORDEN, 1, $largo, 10, 10, 15,
                                       'CODIGO-DE-PRODUCTO-DEMASIADO-LARGO', 0, 11.5, 0, 1);
$comprobar($insertado > 0,
    'una descripcion kilometrica ya NO tumba el guardado del detalle');

$guardado = $pdo->query("SELECT item, codproducto FROM detalle_factura_electronica
                         WHERE id_tabla = " . (int)$insertado)->fetch(PDO::FETCH_ASSOC);
$comprobar(mb_strlen($guardado['item'], 'UTF-8') === SRI_MAX_DESCRIPCION,
    'la descripcion se recorta al maximo del SRI (' . SRI_MAX_DESCRIPCION . ')');
$comprobar(mb_strlen($guardado['codproducto'], 'UTF-8') === SRI_MAX_CODIGO_PRINCIPAL,
    'el codigo de producto se recorta a ' . SRI_MAX_CODIGO_PRINCIPAL . ' (limite de codigoPrincipal)');

// --- La transaccion revierte de verdad --------------------------------------
$modelo->iniciarTransaccion();
$modelo->registrarDetalle($ORDEN_VACIO, 1, 'LINEA QUE NO DEBE QUEDAR', 10, 10, 15, 'INS', 0, 11.5, 0, 1);
$modelo->revertir();
$comprobar($modelo->contarDetalle($ORDEN_VACIO) === 0,
    'lo escrito dentro de una transaccion revertida no queda (cabecera y detalle van juntos)');

// --- El AUTO_INCREMENT no se puede quedar adelantado ------------------------
// El numero de comprobante se calcula como MAX(id)+1 pero el `id` lo pone el
// AUTO_INCREMENT, y una transaccion revertida igual consume su valor. Si el
// contador queda adelantado, la factura siguiente nace con id != orden_no y el
// detalle revienta contra la clave foranea. resetFactura lo realinea.
$autoInc = function () use ($pdo) {
    $f = $pdo->query("SELECT AUTO_INCREMENT FROM information_schema.TABLES
                      WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'datos_cabecera_electronica'")->fetch(PDO::FETCH_ASSOC);
    return (int)$f['AUTO_INCREMENT'];
};
$siguiente = function () use ($modelo) {
    $s = $modelo->getSerieElectronica();
    return (int)$s['total'] + 1;
};

$modelo->iniciarTransaccion();
$pdo2 = null; // el insert va por el modelo, para que entre en SU transaccion
$modelo->registrarEncabezado(
    $HOY, 99003, 'CLIENTE PRUEBA', 'DIR', '09', '0999999999001', 4, '', '001', '002',
    '0999999999001', 2, 'EMPRESA', 'EMPRESA', 99003, 'DIR MATRIZ', 'NO', 0, 10,
    'EFECTIVO', 1, 'CONTADO', 4, 9001
);
$modelo->revertir();
$modelo->resetFactura('datos_cabecera_electronica');

$comprobar($autoInc() === $siguiente(),
    'tras revertir, el AUTO_INCREMENT vuelve a coincidir con el proximo numero de comprobante (' . $siguiente() . ')');

$limpiar();

echo PHP_EOL . "$ok correctas, $mal fallidas" . PHP_EOL;
exit($mal ? 1 : 0);
