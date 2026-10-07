<?php
class VentasModel extends Query
{
    public function __construct()
    {
        parent::__construct();
    }
    public function getProducto($idProducto)
    {
        $sql = "SELECT * FROM productos WHERE id = $idProducto";
        return $this->select($sql);
    }

    public function registrarVenta($productos, $total, $fecha, $hora, $metodo, $descuento, $serie, $idCliente, $idusuario)
    {
        $sql = "INSERT INTO ventas (productos, total, fecha, hora, metodo, descuento, serie, id_cliente, id_usuario) VALUES (?,?,?,?,?,?,?,?,?)";
        $array = array($productos, $total, $fecha, $hora, $metodo, $descuento, $serie, $idCliente, $idusuario);
        return $this->insertar($sql, $array);
    }

    public function actualizarStock($cantidad, $ventas, $idProducto)
    {
        $sql = "UPDATE productos SET cantidad = ? , ventas = ? WHERE id = ?";
        $array = array($cantidad, $ventas, $idProducto);
        return $this->save($sql, $array);
    }
    public function registrarCredito($monto, $fecha, $hora, $idVenta, $idElectronica)
    {
        $sql = "INSERT INTO creditos (monto, fecha, hora, id_venta, id_electronica) VALUES (?,?,?,?,?)";
        $array = array($monto, $fecha, $hora, $idVenta, $idElectronica);
        return $this->insertar($sql, $array);
    }
    public function getEmpresa()
    {
        $sql = "SELECT * FROM configuracion";
        return $this->select($sql);
    }

    public function getVenta($idVenta)
    {
        $sql = "SELECT v.*, c.identidad, c.num_identidad, c.nombre, c.telefono, c.direccion FROM ventas v INNER JOIN clientes c ON v.id_cliente = c.id WHERE v.id = $idVenta";
        return $this->select($sql);
    }
    public function getVentaElectronica($idVenta)
    {
        $sql = "SELECT dce.cliente,dce.fecha,dce.orden_no,dce.ruc,dce.estado,dce.totalfactura,dce.claveacceso,dfe.cantidad,dfe.codproducto,p.id,dce.metodo,c.correo FROM datos_cabecera_electronica dce
        INNER JOIN detalle_factura_electronica dfe ON dfe.orden_no=dce.orden_no 
        INNER JOIN productos p ON p.codigo=dfe.codproducto
        INNER JOIN clientes c ON c.num_identidad=dce.ruc
        WHERE dce.orden_no = $idVenta";
        return $this->selectAll($sql);
    }

    public function getVentas()
    {
        $sql = "SELECT v.*, c.nombre FROM ventas v INNER JOIN clientes c ON v.id_cliente = c.id";
        return $this->selectAll($sql);
    }

    /**
     * FROM + JOIN + WHERE compartidos por el listado paginado y el conteo de
     * facturas electronicas (DataTables serverSide). Toda entrada del usuario
     * va por $params; aqui no se concatena nada.
     *
     * - LEFT JOIN respuesta_sri: mostrar ventas aunque aun no tengan respuesta del SRI.
     * - dce_auth/rs_auth: ocultar la copia no autorizada cuando existe otra factura
     *   identica (mismo ruc, fecha y total) que si fue autorizada.
     * - Ventana: desde el dia 1 de hace 11 meses.
     *
     * @param string $search       texto del buscador de DataTables
     * @param string $filtroSri    '' | AUTORIZADO | NO AUTORIZADO | DEVUELTA | EN PROCESO
     * @param string $filtroCorreo '' | ENVIADO | NO ENVIADO | EMAIL INVÁLIDO | ARCHIVOS PERDIDOS | SIN CORREO
     */
    private function ventasElectronicaFromWhere($search, $filtroSri, $filtroCorreo, array &$params)
    {
        $sql = " FROM datos_cabecera_electronica dce
                LEFT JOIN respuesta_sri rs ON rs.claveAcceso = dce.claveacceso
                LEFT JOIN clientes cl ON cl.num_identidad = dce.ruc
                LEFT JOIN datos_cabecera_electronica dce_auth
                  ON dce_auth.ruc = dce.ruc AND dce_auth.fecha = dce.fecha AND dce_auth.totalfactura = dce.totalfactura AND dce_auth.id != dce.id
                LEFT JOIN respuesta_sri rs_auth ON rs_auth.claveAcceso = dce_auth.claveacceso AND rs_auth.estado = 'AUTORIZADO'
                WHERE dce.fecha >= DATE_FORMAT(DATE_SUB(CURDATE(), INTERVAL 11 MONTH), '%Y-%m-01')
                  AND (rs.estado = 'AUTORIZADO' OR rs_auth.id IS NULL)";

        // Buscador global: cliente, numero de factura, ruc, clave de acceso y el
        // estado SRI tal como se muestra en el badge (EN PROCESO agrupa el resto).
        $sql .= buildSearchClause($search, [
            'LOWER(dce.cliente)',
            'CAST(dce.orden_no AS CHAR)',
            'dce.ruc',
            'dce.claveacceso',
            "LOWER(CASE WHEN rs.estado IN ('AUTORIZADO','NO AUTORIZADO','DEVUELTA') THEN rs.estado ELSE 'EN PROCESO' END)",
        ], $params, ' AND ');

        // Filtro por estado SRI (dropdown). Whitelist: cualquier otro valor se ignora.
        $filtroSri = strtoupper(trim((string)$filtroSri));
        if (in_array($filtroSri, ['AUTORIZADO', 'NO AUTORIZADO', 'DEVUELTA'], true)) {
            $sql .= ' AND rs.estado = ?';
            $params[] = $filtroSri;
        } else if ($filtroSri === 'EN PROCESO') {
            $sql .= " AND (rs.estado IS NULL OR rs.estado NOT IN ('AUTORIZADO','NO AUTORIZADO','DEVUELTA'))";
        }

        // Filtro por estado de correo (dropdown). Replica la logica del badge del
        // controlador; la validez del email se aproxima con REGEXP (filter_var no existe en SQL).
        $filtroCorreo = strtoupper(trim((string)$filtroCorreo));
        $correoTxt   = "TRIM(COALESCE(dce.correo, ''))";
        $emailRegexp = '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$';
        if ($filtroCorreo === 'SIN CORREO') {
            $sql .= " AND $correoTxt = ''";
        } else if ($filtroCorreo === 'EMAIL INVÁLIDO' || $filtroCorreo === 'EMAIL INVALIDO') {
            $sql .= " AND $correoTxt <> '' AND NOT ($correoTxt REGEXP ?)";
            $params[] = $emailRegexp;
        } else if ($filtroCorreo === 'ENVIADO') {
            $sql .= " AND $correoTxt REGEXP ? AND dce.correo_enviado = 1";
            $params[] = $emailRegexp;
        } else if ($filtroCorreo === 'ARCHIVOS PERDIDOS') {
            $sql .= " AND $correoTxt REGEXP ? AND dce.correo_enviado = 2";
            $params[] = $emailRegexp;
        } else if ($filtroCorreo === 'NO ENVIADO') {
            $sql .= " AND $correoTxt REGEXP ? AND COALESCE(dce.correo_enviado, 0) NOT IN (1, 2)";
            $params[] = $emailRegexp;
        }

        return $sql;
    }

    /**
     * Pagina del listado de facturas electronicas (DataTables serverSide).
     * Las subconsultas correlacionadas (facturas_previas_mes, contratos_activos)
     * solo se evaluan para las filas de la pagina.
     */
    public function getVentasElectronicaPaginado($start, $length, $search, $filtroSri = '', $filtroCorreo = '')
    {
        $params = [];
        $sql = "SELECT dce.fecha, TIME_FORMAT(rs.createdAt, '%H:%i:%s') AS hora,
                       dce.orden_no, dce.cliente, dce.estado, dce.totalfactura, dce.claveacceso,
                       dce.correo, dce.correo_enviado, dce.codigo_pago,
                       cl.id AS id_cliente,
                       COALESCE(rs.estado, 'PENDIENTE') AS autorizacion,
                       (
                         SELECT COUNT(*) FROM datos_cabecera_electronica d2
                         INNER JOIN respuesta_sri r2 ON r2.claveAcceso=d2.claveacceso
                         WHERE d2.ruc = dce.ruc AND r2.estado='AUTORIZADO'
                           AND d2.fecha >= DATE_FORMAT(dce.fecha, '%Y-%m-01')
                           AND d2.fecha <  DATE_FORMAT(DATE_ADD(dce.fecha, INTERVAL 1 MONTH), '%Y-%m-01')
                           AND d2.id < dce.id
                       ) AS facturas_previas_mes,
                       (
                         SELECT COUNT(*) FROM contratos c WHERE c.id_cliente=cl.id AND c.estado=1 AND c.factura=1
                       ) AS contratos_activos";
        $sql .= $this->ventasElectronicaFromWhere($search, $filtroSri, $filtroCorreo, $params);
        $start  = max(0, intval($start));
        $length = (intval($length) > 0 && intval($length) <= 100) ? intval($length) : 25;
        $sql .= " GROUP BY dce.id
                ORDER BY dce.id DESC LIMIT $start, $length";
        return $this->select2($sql, $params);
    }

    /**
     * Conteo con los mismos JOIN/WHERE del listado. Con $search vacio devuelve
     * recordsTotal; con busqueda/filtros devuelve recordsFiltered.
     */
    public function contarVentasElectronica($search, $filtroSri = '', $filtroCorreo = '')
    {
        $params = [];
        $sql = 'SELECT COUNT(DISTINCT dce.id) AS c';
        $sql .= $this->ventasElectronicaFromWhere($search, $filtroSri, $filtroCorreo, $params);
        $r = $this->select2($sql, $params);
        return $r ? intval($r[0]['c']) : 0;
    }

    public function anular($idVenta)
    {
        $sql = "UPDATE ventas SET estado = ? WHERE id = ?";
        $array = array(0, $idVenta);
        return $this->save($sql, $array);
    }
    public function anularElectronica($idVenta)
    {
        $sql = "UPDATE datos_cabecera_electronica SET estado = ? WHERE orden_no = ?";
        $array = array(0, $idVenta);
        return $this->save($sql, $array);
    }
    public function anularCredito($idVenta, $tabla)
    {
        if ($tabla == 'fisico') {
            $sql = "UPDATE creditos SET estado = ? WHERE id_venta = ?";
            $array = array(2, $idVenta);
            return $this->save($sql, $array);
        } else {
            $sql = "UPDATE creditos SET estado = ? WHERE id_electronica = ?";
            $array = array(2, $idVenta);
            return $this->save($sql, $array);
        }

    }

    public function getSerie()
    {
        $sql = "SELECT MAX(id) AS total FROM ventas";
        return $this->select($sql);
    }
    public function getSerieElectronica()
    {
        $sql = "SELECT MAX(id) AS total FROM datos_cabecera_electronica";
        return $this->select($sql);
    }
    //movimiento
    public function registrarMovimiento($movimiento, $accion, $cantidad, $stockActual, $idProducto, $id_usuario)
    {
        $sql = "INSERT INTO inventario (movimiento, accion, cantidad, stock_actual, id_producto, id_usuario) VALUES (?,?,?,?,?,?)";
        $array = array($movimiento, $accion, $cantidad, $stockActual, $idProducto, $id_usuario);
        return $this->insertar($sql, $array);
    }

    public function getCaja($id_usuario)
    {
        $sql = "SELECT * FROM cajas WHERE estado = 1 AND id_usuario = $id_usuario";
        return $this->select($sql);
    }

    //registro de facturacion Electronica

    public function registrarEncabezado(
        $fecha,
        $numSerieElectronica,
        $clienteNombre,
        $clienteDireccion,
        $clienteTelefono,
        $clienteRuc,
        $tipoIdentificacion,
        $clienteCorreo,
        $empresaEstablecimiento,
        $empresaPuntoemi,
        $empresaRuc,
        $ambiente,
        $empresaRazon,
        $empresaNombre,
        $secuencial,
        $empresaDireccion,
        $empresaObligado,
        $descuento,
        $total,
        $tipoPago,
        $estado,
        $metodo,
        $idusuario,
        $idCliente
    ) {
        $sql = "INSERT INTO datos_cabecera_electronica (fecha, orden_no, cliente, direccion,telefono, ruc,tipo_identificacion,
         correo,establecimiento,punto_emi,ruc_empresa,ambiente,razon_social,nombre_comercial,secuencial,
         direccion_matriz,obligado,totaldescuento,totalfactura,tipopago,estado,metodo,id_usuario,id_cliente) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)";
        $array = array(
            $fecha,
            $numSerieElectronica,
            $clienteNombre,
            $clienteDireccion,
            $clienteTelefono,
            $clienteRuc,
            $tipoIdentificacion,
            $clienteCorreo,
            $empresaEstablecimiento,
            $empresaPuntoemi,
            $empresaRuc,
            $ambiente,
            $empresaRazon,
            $empresaNombre,
            $secuencial,
            $empresaDireccion,
            $empresaObligado,
            $descuento,
            $total,
            $tipoPago,
            $estado,
            $metodo,
            $idusuario,
            $idCliente
        );
        return $this->insertar($sql, $array);
    }
    public function registrarDetalle($numSerieElectronica, $cantidad, $descripcion, $precio, $total, $iva, $codigo, $descuentoDetalle, $precio_pvp, $descuento, $idProducto)
    {
        // Se recorta a lo que admite el SRI antes de tocar la base. Si no, una
        // descripcion larga lanza "Data too long for column 'item'" y la factura
        // se queda sin lineas (la cabecera ya estaba insertada).
        $descripcion = recortarCampoSri($descripcion, SRI_MAX_DESCRIPCION, 'item', $numSerieElectronica);
        $codigo = recortarCampoSri($codigo, SRI_MAX_CODIGO_PRINCIPAL, 'codproducto', $numSerieElectronica);
        $sql = "INSERT INTO detalle_factura_electronica (orden_no, cantidad, item, precio_u,total, iva,codproducto,descuento,precio_pvp,por_descuento,id_producto) VALUES (?,?,?,?,?,?,?,?,?,?,?)";
        $array = array($numSerieElectronica, $cantidad, $descripcion, $precio, $total, $iva, $codigo, $descuentoDetalle, $precio_pvp, $descuento, $idProducto);
        return $this->insertar($sql, $array);
    }

    /** Cuantas lineas tiene ya un comprobante. 0 = no se puede enviar al SRI. */
    public function contarDetalle($ordenNo)
    {
        $sql = "SELECT COUNT(*) AS total FROM detalle_factura_electronica WHERE orden_no = ?";
        $data = $this->select($sql, array($ordenNo));
        return isset($data['total']) ? (int)$data['total'] : 0;
    }

    /**
     * Guarda la clave de acceso y el estado REAL del comprobante.
     *
     * $autorizado: null = no se sabe (se mantiene el comportamiento de siempre,
     * para no cambiar a los demas llamadores); true = el SRI lo autorizo;
     * false = el SRI NO lo autorizo.
     *
     * Antes esto escribia siempre estado_proceso=1, sri_enviado=1 y
     * correo_enviado=1 sin mirar la respuesta del SRI. Como el panel cuenta
     * estado_proceso=1 como "autorizada", una factura devuelta se veia emitida;
     * y como cron_sri_facturas busca estado_proceso=0 y cron_sri_reintentos
     * busca estado_proceso=2, el 1 no caia en ninguno y la factura quedaba
     * varada para siempre ("Facturas a reintentar: 0" con facturas pendientes).
     * Con estado_proceso=2 el cron de reintentos SI la vuelve a tomar.
     */
    public function actualizarClaveAccesso($claveAccesso, $idVenta, $autorizado = null, $mensajeSri = '')
    {
        if ($autorizado === false) {
            $sql = "UPDATE datos_cabecera_electronica
                    SET claveacceso = ?, estado_proceso = 2, sri_enviado = 1, correo_enviado = 0, mensaje_sri = ?
                    WHERE orden_no = ?";
            return $this->save($sql, array($claveAccesso, mb_substr((string)$mensajeSri, 0, 250), $idVenta));
        }
        $sql = "UPDATE datos_cabecera_electronica SET claveacceso = ?, estado_proceso = 1, sri_enviado = 1, correo_enviado = 1 WHERE orden_no = ?";
        $array = array($claveAccesso, $idVenta);
        return $this->save($sql, $array);
    }

    public function getFacturaElectronica($claveAccesso)
    {

        $sql = "SELECT * FROM datos_cabecera_electronica WHERE claveacceso = '$claveAccesso'";
        return $this->select($sql);
    }
    public function getFacturaElectronicaDetalle($orden_no)
    {
        $sql = "SELECT orden_no, cantidad, item, precio_u, total, iva, codproducto 
        FROM detalle_factura_electronica WHERE orden_no = $orden_no";
        return $this->selectAll($sql);
    }

    public function deleteFactura($tabla, $campo, $orden_no)
    {
        $sql = "DELETE FROM $tabla WHERE $campo = $orden_no";
        return $this->select($sql);
    }
    public function resetFactura($campo)
    {
        $sql = "ALTER TABLE $campo AUTO_INCREMENT=1";
        return $this->select($sql);
    }
    //datos cliente factura electronica
    public function getCliente($idCliente)
    {
        $sql = "SELECT * FROM clientes WHERE id = $idCliente";
        return $this->select($sql);
    }
    public function getClientes()
    {
        $sql = "SELECT * FROM clientes";
        return $this->selectAll($sql);
    }
    public function cantidadDocumento($fechaActual)
    {
        $sql = "SELECT COUNT(id) AS cantidad FROM datos_cabecera_electronica WHERE fecha LIKE '$fechaActual%'";
        return $this->selectAll($sql);
    }
    public function tipoPago()
    {
        $sql = "SELECT * FROM tipo_pago";
        return $this->selectAll($sql);
    }

    /** Facturas que requieren reintento al SRI (sin AUTORIZADO). */
    public function getSriPendientes($limite = 5)
    {
        $limite = max(1, min(50, (int)$limite));
        // Filtro anti-zombies v2 (2026-06-05):
        //  - Si NO hay gemela autorizada por ruc+fecha+total -> reintentar.
        //  - Si SI hay gemela -> reintentar solo si el cliente aun tiene cupo
        //    (autorizadas_del_cliente_esa_fecha < contratos_facturables_del_cliente).
        //    Asi distingue duplicado real (cupo lleno) de contrato distinto.
        $sql = "SELECT dce.orden_no
                FROM datos_cabecera_electronica dce
                LEFT JOIN respuesta_sri rs ON rs.claveAcceso = dce.claveacceso
                WHERE dce.fecha >= DATE_FORMAT(CURDATE(), '%Y-%m-01')
                  AND dce.fecha <  DATE_FORMAT(DATE_ADD(CURDATE(), INTERVAL 1 MONTH), '%Y-%m-01')
                  AND (rs.estado IS NULL OR rs.estado IN ('NO AUTORIZADO','EN PROCESO','DEVUELTA','PENDIENTE','RECIBIDA'))
                  AND EXISTS (SELECT 1 FROM detalle_factura_electronica dfe WHERE dfe.orden_no = dce.orden_no)
                  AND (
                    NOT EXISTS (
                      SELECT 1 FROM datos_cabecera_electronica dce_auth
                      INNER JOIN respuesta_sri rs_auth ON rs_auth.claveAcceso = dce_auth.claveacceso AND rs_auth.estado='AUTORIZADO'
                      WHERE dce_auth.ruc = dce.ruc AND dce_auth.fecha = dce.fecha
                        AND dce_auth.totalfactura = dce.totalfactura AND dce_auth.id != dce.id
                    )
                    OR (
                      (SELECT COUNT(*) FROM datos_cabecera_electronica d2
                       INNER JOIN respuesta_sri r2 ON r2.claveAcceso = d2.claveacceso AND r2.estado='AUTORIZADO'
                       WHERE d2.id_cliente = dce.id_cliente AND d2.fecha = dce.fecha)
                      <
                      (SELECT COUNT(*) FROM contratos c
                       WHERE c.id_cliente = dce.id_cliente AND c.estado=1 AND c.factura=1)
                    )
                  )
                GROUP BY dce.id
                ORDER BY dce.id DESC
                LIMIT $limite";
        return $this->selectAll($sql);
    }

    /** Facturas autorizadas con email valido y correo_enviado=0, listas para reenviar. */
    public function getVentasElectronicaUnica($ordenNo)
    {
        $sql = "SELECT dce.orden_no, dce.cliente, COALESCE(rs.estado, 'PENDIENTE') AS autorizacion
                FROM datos_cabecera_electronica dce
                LEFT JOIN respuesta_sri rs ON rs.claveAcceso = dce.claveacceso
                WHERE dce.orden_no = ?";
        return $this->selectAllPrepared($sql, [$ordenNo]);
    }

    public function getCorreosPendientes($limite = 20)
    {
        $limite = max(1, min(100, (int)$limite));
        $sql = "SELECT dce.orden_no, dce.cliente, dce.correo, dce.claveacceso, dce.fecha, dce.totalfactura, dce.ruc, dce.establecimiento, dce.punto_emi
                FROM datos_cabecera_electronica dce
                INNER JOIN respuesta_sri rs ON rs.claveAcceso = dce.claveacceso
                WHERE rs.estado = 'AUTORIZADO' AND dce.correo_enviado = 0
                  AND dce.correo IS NOT NULL AND dce.correo != ''
                  AND dce.correo REGEXP '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
                ORDER BY dce.id DESC
                LIMIT $limite";
        return $this->selectAll($sql);
    }

    public function marcarCorreoEnviado($ordenNo)
    {
        $sql = "UPDATE datos_cabecera_electronica SET correo_enviado = 1 WHERE orden_no = ?";
        return $this->save($sql, [$ordenNo]);
    }
}
