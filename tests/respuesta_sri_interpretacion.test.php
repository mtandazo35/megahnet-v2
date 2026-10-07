<?php
/**
 * Prueba de como se interpreta la respuesta del SRI.
 *
 * No necesita base de datos. Extrae los METODOS REALES del controlador
 * (controllers/Ventas.php) y los ejecuta con las respuestas que el SRI devolvio
 * de verdad en rutanet el 2026-10-02, 05 y 07 — las que estan guardadas en
 * facturaelectronica/errores/*.txt.
 *
 * Antes de este arreglo el controlador llamaba a actualizarClaveAccesso() sin
 * mirar la respuesta, asi que estas tres facturas quedaron marcadas como
 * autorizadas y enviadas por correo cuando el SRI las habia devuelto.
 *
 * Uso:  php tests/respuesta_sri_interpretacion.test.php
 */

require_once dirname(__DIR__) . '/config/Helpers.php';

/** Saca el codigo de un metodo del controlador contando llaves. */
function extraerMetodo($codigo, $nombre)
{
    $inicio = strpos($codigo, 'private function ' . $nombre . '(');
    if ($inicio === false) {
        fwrite(STDERR, "No se encontro el metodo $nombre en controllers/Ventas.php\n");
        exit(2);
    }
    $llave = strpos($codigo, '{', $inicio);
    $nivel = 0;
    for ($i = $llave; $i < strlen($codigo); $i++) {
        if ($codigo[$i] === '{') $nivel++;
        if ($codigo[$i] === '}') {
            $nivel--;
            if ($nivel === 0) {
                return str_replace('private function', 'public function',
                                   substr($codigo, $inicio, $i - $inicio + 1));
            }
        }
    }
    fwrite(STDERR, "Metodo $nombre sin cerrar\n");
    exit(2);
}

$fuente = file_get_contents(dirname(__DIR__) . '/controllers/Ventas.php');
eval('class LecturaSri {'
     . extraerMetodo($fuente, 'interpretarRespuestaSri') . "\n"
     . extraerMetodo($fuente, 'mensajeSri')
     . '}');
$sri = new LecturaSri();

// --- Respuestas reales del SRI ----------------------------------------------
$devueltaSinDetalle = array(
    'estado' => 'DEVUELTA',
    'comprobantes' => array('comprobante' => array(
        'claveAcceso' => '0210202601120087817900120010020000016280000162811',
        'mensajes' => array('mensaje' => array(
            'identificador' => 35,
            'mensaje' => 'ARCHIVO NO CUMPLE ESTRUCTURA XML',
            'informacionAdicional' => "Se encontro el siguiente error en la estructura del comprobante: cvc-complex-type.2.4.b: The content of element 'detalles' is not complete. One of '{detalle}' is expected..",
            'tipo' => 'ERROR',
        )),
    )),
);

$devueltaCodigoLargo = array(
    'estado' => 'DEVUELTA',
    'comprobantes' => array('comprobante' => array(
        'mensajes' => array('mensaje' => array(
            'identificador' => 35,
            'mensaje' => 'ARCHIVO NO CUMPLE ESTRUCTURA XML',
            'informacionAdicional' => "cvc-maxLength-valid: Value 'TERCERA EDAD / DISCAPACITADO' with length = '28' is not facet-valid with respect to maxLength '25' for type 'codigoPrincipal'..",
            'tipo' => 'ERROR',
        )),
    )),
);

$autorizada = array('estado' => 'RECIBIDA');
$autorizacionOk = array(
    'numeroComprobantes' => 1,
    'autorizaciones' => array('autorizacion' => array('estado' => 'AUTORIZADO')),
);
$autorizacionNinguna = array(
    'numeroComprobantes' => 0,
    'autorizaciones' => array('autorizacion' => array('estado' => '')),
);
// Lo que el propio controlador arma cuando el SOAP del SRI se cae.
$autorizacionSoapCaido = array(
    'numeroComprobantes' => 1,
    'autorizaciones' => array('autorizacion' => array('estado' => 'NO_AUTORIZADO')),
);
$yaRegistrada = array(
    'estado' => 'DEVUELTA',
    'comprobantes' => array('comprobante' => array(
        'mensajes' => array('mensaje' => array(
            'identificador' => 43,
            'mensaje' => 'CLAVE ACCESO REGISTRADA',
            'tipo' => 'ERROR',
        )),
    )),
);

// --- Lo que se espera -------------------------------------------------------
$casos = array(
    array('factura sin lineas (doc 1628 y 1631, $1.414,50)',
          $devueltaSinDetalle, $autorizacionOk, false, 'detalles'),
    array('codigo de producto de 28 caracteres (doc 1630)',
          $devueltaCodigoLargo, $autorizacionOk, false, 'codigoPrincipal'),
    array('factura correcta y autorizada',
          $autorizada, $autorizacionOk, true, null),
    array('el SRI no devuelve ningun comprobante',
          $autorizada, $autorizacionNinguna, false, null),
    array('el SOAP del SRI se cayo',
          null, $autorizacionSoapCaido, false, null),
    array('el SRI ya la tenia registrada y esta autorizada',
          $yaRegistrada, $autorizacionOk, true, null),
    array('el SRI ya la tenia registrada pero NO autorizada',
          $yaRegistrada, $autorizacionSoapCaido, false, null),
);

$ok = 0; $mal = 0;
foreach ($casos as $caso) {
    list($titulo, $validacion, $autorizacion, $esperado, $debeMencionar) = $caso;
    $r = $sri->interpretarRespuestaSri($validacion, $autorizacion);

    if ($r['autorizado'] !== $esperado) {
        printf("  FALLA %s -> autorizado=%s y se esperaba %s\n", $titulo,
               var_export($r['autorizado'], true), var_export($esperado, true));
        $mal++;
        continue;
    }
    if ($debeMencionar !== null && strpos($r['mensaje'], $debeMencionar) === false) {
        printf("  FALLA %s -> el mensaje no explica el motivo (falta \"%s\"): %s\n",
               $titulo, $debeMencionar, $r['mensaje']);
        $mal++;
        continue;
    }
    printf("  OK    %-52s %s\n", $titulo, $esperado ? '(autorizada)' : '(NO autorizada)');
    $ok++;
}

// --- El recorte de campos ---------------------------------------------------
$recortes = array(
    array(str_repeat('a', 400), SRI_MAX_DESCRIPCION, SRI_MAX_DESCRIPCION, 'descripcion de 400 -> 300'),
    array('SERVICIO NORMAL', SRI_MAX_DESCRIPCION, 15, 'descripcion corta se deja igual'),
    array('TERCERA EDAD / DISCAPACITADO', SRI_MAX_CODIGO_PRINCIPAL, SRI_MAX_CODIGO_PRINCIPAL, 'codigo de 28 -> 25'),
    array('INS', SRI_MAX_CODIGO_PRINCIPAL, 3, 'codigo corto se deja igual'),
    array('ÑOÑO ÁCENTOS ÜÜ', SRI_MAX_DESCRIPCION, 15, 'cuenta caracteres, no bytes (tildes y enies)'),
);
foreach ($recortes as $r) {
    list($entrada, $max, $largoEsperado, $titulo) = $r;
    $salida = recortarCampoSri($entrada, $max, 'prueba');
    if (mb_strlen($salida, 'UTF-8') === $largoEsperado) {
        printf("  OK    %s\n", $titulo);
        $ok++;
    } else {
        printf("  FALLA %s -> quedo en %d caracteres\n", $titulo, mb_strlen($salida, 'UTF-8'));
        $mal++;
    }
}

echo PHP_EOL . "$ok correctas, $mal fallidas" . PHP_EOL;
exit($mal ? 1 : 0);
