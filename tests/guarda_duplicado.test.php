<?php
/**
 * Prueba de la guarda que impide facturar dos veces el mismo mes.
 *
 * Usa el MODELO REAL (AutomaticasModel::getContratosFacturar) contra una base
 * temporal con contratos de juguete. No toca produccion: la base se indica por
 * la variable de entorno DB_NAME, que tiene prioridad sobre el .env.
 *
 * El caso que motivo esta prueba (2026-10-02, rutanet): el dia 1 se facturaron
 * 12 contratos a mano desde el panel, y ese camino no marca mes_facturar. Al
 * correr el cron el dia 2 los vio pendientes y los facturo otra vez. La guarda
 * existia, pero solo miraba creditos del MISMO DIA.
 *
 * Uso (en el servidor, con la base temporal ya creada):
 *   DB_NAME=prueba_guarda php tests/guarda_duplicado.test.php
 */

require_once dirname(__DIR__) . '/config/Config.php';
require_once dirname(__DIR__) . '/config/Helpers.php';
require_once dirname(__DIR__) . '/config/app/Autoload.php';

$mes       = strtolower(MESES[(int)date('n')]); // columna del mes en curso (en minusculas)
$primerDia = date('Y-m-01');
$hoy       = date('Y-m-d');
$mesPasado = date('Y-m-15', strtotime('-1 month'));

$pdo = new PDO('mysql:host=' . HOSTT . ';dbname=' . DBNAME . ';charset=utf8mb4', USER, PASSWORD,
               [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);

echo "base de pruebas: " . DBNAME . " | mes: $mes\n\n";

// --- contratos de juguete ---------------------------------------------------
// Se apagan las claves foraneas: solo interesan las cuatro tablas de la consulta.
$pdo->exec('SET FOREIGN_KEY_CHECKS=0');
foreach ([9001, 9002, 9003, 9004, 9005] as $id) {
    $pdo->exec("DELETE FROM creditos      WHERE id_contrato = $id");
    $pdo->exec("DELETE FROM mes_facturar  WHERE id_contrato = $id");
    $pdo->exec("DELETE FROM contratos     WHERE id = $id");
    $pdo->exec("DELETE FROM clientes      WHERE id = $id");
}

$productos = '[{"id":1,"nombre":"PLAN PRUEBA","precio":25,"cantidad":1}]';
foreach ([9001, 9002, 9003, 9004, 9005] as $id) {
    // identidad / num_identidad son obligatorias en el esquema real.
    $pdo->exec("INSERT INTO clientes (id, identidad, num_identidad, nombre, estado)
                VALUES ($id, 'CEDULA', '99999999$id', 'CLIENTE $id', 1)");
    $pdo->exec("INSERT INTO contratos (id, fecha, hora, id_cliente, id_usuario, productos, total,
                ip_usuario, repetidora, ap, estado, factura)
                VALUES ($id, '$primerDia', '00:00:00', $id, 4, '$productos', 25.00, '', '', '', 1, 0)");
}

// mes_facturar: 0 = pendiente de facturar este mes
$pdo->exec("INSERT INTO mes_facturar (id_contrato, $mes, estado) VALUES
            (9001, 0, 1), (9002, 0, 1), (9003, 0, 1), (9004, 0, 1), (9005, 1, 1)");

// creditos: la senal de que ese contrato ya se cobro
$pdo->exec("INSERT INTO creditos (monto, fecha, hora, estado, id_contrato) VALUES
            (25.00, '$hoy',       '10:00:00', 1, 9002),
            (25.00, '$primerDia', '02:00:00', 1, 9003),
            (25.00, '$mesPasado', '02:00:00', 1, 9004)");

// --- lo que se espera -------------------------------------------------------
$casos = [
    9001 => [true,  'sin ningun credito: hay que facturarlo'],
    9002 => [false, 'ya tiene credito de HOY'],
    9003 => [false, 'ya tiene credito del dia 1 de ESTE MES (el caso que fallaba)'],
    9004 => [true,  'su ultimo credito es del mes pasado: toca facturar'],
    9005 => [false, 'el mes ya esta marcado como facturado'],
];

// --- se pregunta al modelo REAL --------------------------------------------
$modelo    = new AutomaticasModel();
$devueltos = [];
foreach ($modelo->getContratosFacturar($mes, 1, 0, 0) as $fila) {
    $devueltos[(int)$fila['id']] = true;
}

$ok = 0; $mal = 0;
foreach ($casos as $id => [$deberiaSalir, $motivo]) {
    $salio = isset($devueltos[$id]);
    if ($salio === $deberiaSalir) {
        printf("  OK    %d %-14s %s\n", $id, $salio ? '(se factura)' : '(se omite)', $motivo);
        $ok++;
    } else {
        printf("  FALLA %d: %s -> %s\n", $id, $motivo,
               $salio ? 'LO FACTURARIA (duplicado)' : 'NO lo factura y deberia');
        $mal++;
    }
}

// --- limpieza ---------------------------------------------------------------
foreach ([9001, 9002, 9003, 9004, 9005] as $id) {
    $pdo->exec("DELETE FROM creditos     WHERE id_contrato = $id");
    $pdo->exec("DELETE FROM mes_facturar WHERE id_contrato = $id");
    $pdo->exec("DELETE FROM contratos    WHERE id = $id");
    $pdo->exec("DELETE FROM clientes     WHERE id = $id");
}

echo "\n$ok correctas, $mal fallidas\n";
exit($mal ? 1 : 0);
