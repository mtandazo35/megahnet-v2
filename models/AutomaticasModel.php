<?php

class AutomaticasModel extends Query
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
        $sql = 'INSERT INTO ventas (productos, total, fecha, hora, metodo, descuento, serie, id_cliente, id_usuario) VALUES (?,?,?,?,?,?,?,?,?)';
        $array = array($productos, $total, $fecha, $hora, $metodo, $descuento, $serie, $idCliente, $idusuario);
        return $this->insertar($sql, $array);
    }

    public function actualizarStock($cantidad, $ventas, $idProducto)
    {
        $sql = 'UPDATE productos SET cantidad = ? , ventas = ? WHERE id = ?';
        $array = array($cantidad, $ventas, $idProducto);
        return $this->save($sql, $array);
    }

    public function registrarCredito($monto, $fecha, $hora, $idVenta, $idElectronica, $idOrdenVenta, $idContrato)
    {
        $sql = 'INSERT INTO creditos (monto, fecha, hora, id_venta, id_electronica,id_orden_venta,id_contrato) VALUES (?,?,?,?,?,?,?)';
        $array = array($monto, $fecha, $hora, $idVenta, $idElectronica, $idOrdenVenta, $idContrato);
        return $this->insertar($sql, $array);
    }

    public function getEmpresa()
    {
        $sql = 'SELECT * FROM configuracion';
        return $this->select($sql);
    }
    public function estadoCorte($fechaCorte, $nombre)
    {
        $sql = "SELECT COUNT(*) AS total FROM estado_corte WHERE fecha = '$fechaCorte' AND nombre = '$nombre'";
        return $this->select($sql);
    }
    public function getVentaElectronica($idVenta)
    {
        $sql = "SELECT dce.fecha,dce.orden_no,dce.ruc,dce.cliente,dce.estado,dce.totalfactura,dce.claveacceso,dfe.cantidad,dfe.codproducto,p.id,dce.metodo,c.correo FROM datos_cabecera_electronica dce
        INNER JOIN detalle_factura_electronica dfe ON dfe.orden_no=dce.orden_no 
        INNER JOIN productos p ON p.codigo=dfe.codproducto
        INNER JOIN clientes c ON c.num_identidad=dce.ruc
        WHERE dce.orden_no = $idVenta";
        return $this->selectAll($sql);
    }

    public function getContratosFacturar($mesFacturar, $estado, $valor, $limite = 0)
    {
        // Idempotencia v3 (2026-10-02): se excluyen los contratos que ya tienen
        // un credito de ESTE MES, no solo del mismo dia.
        //
        // La version anterior miraba CURDATE() y eso dejo pasar un caso real: el
        // 2026-10-01 se facturaron 12 contratos a mano desde el panel, y ese
        // camino no marca mes_facturar. Al correr el cron el dia 2 los vio
        // pendientes y los facturo otra vez: 10 clientes con dos ordenes del
        // mismo mes.
        //
        // Los seis sitios que usan esta consulta facturan siempre el mes en
        // curso, asi que mirar el mes completo no deja fuera ningun caso
        // legitimo. La marca de mes_facturar sigue siendo la via principal;
        // esto es la red por si esa marca falla, que es justo lo que paso.
        $sql = "SELECT c.id,c.productos,c.total,c.direccion,c.comentario,cl.id AS idCliente ,cl.nombre,c.estado,c.factura FROM contratos c
        INNER JOIN clientes cl ON cl.id=c.id_cliente
        INNER JOIN mes_facturar mf ON mf.id_contrato=c.id
        WHERE mf.$mesFacturar = 0 AND c.estado = $estado AND c.factura = $valor
          AND NOT EXISTS (
                SELECT 1 FROM creditos cr
                WHERE cr.id_contrato = c.id
                  AND cr.fecha >= DATE_FORMAT(CURDATE(), '%Y-%m-01')
                  AND cr.fecha <  DATE_FORMAT(CURDATE() + INTERVAL 1 MONTH, '%Y-%m-01')
          )";
        $limite = (int)$limite;
        if ($limite > 0) { $sql .= " LIMIT " . $limite; }
        return $this->selectAll($sql);
    }

    /**
     * Lista TODOS los contratos activos del mes con su estado de emision.
     * mfemitido = 1 si ya esta marcado como facturado en mes_facturar.<mesFacturar>.
     */
    public function getContratosFacturarConEstado($mesFacturar, $estado, $valor)
    {
        $sql = "SELECT c.id, c.productos, c.total, c.direccion, c.comentario,
                       cl.id AS idCliente, cl.nombre, c.estado, c.factura,
                       mf.$mesFacturar AS mfemitido
                FROM contratos c
                INNER JOIN clientes cl ON cl.id = c.id_cliente
                INNER JOIN mes_facturar mf ON mf.id_contrato = c.id
                WHERE c.estado = $estado AND c.factura = $valor";
        return $this->selectAll($sql);
    }

    public function anularCredito($idVenta, $tabla)
    {
        if ($tabla == 'fisico') {
            $sql = 'UPDATE creditos SET estado = ? WHERE id_venta = ?';
            $array = array(2, $idVenta);
            return $this->save($sql, $array);
        } else {
            $sql = 'UPDATE creditos SET estado = ? WHERE id_electronica = ?';
            $array = array(2, $idVenta);
            return $this->save($sql, $array);
        }
    }
   
    public function getSerieOrdenVenta()
    {
        $sql = "SELECT MAX(id) AS total FROM orden_venta";
        return $this->select($sql);
    }
    public function getSerieElectronica()
    {
        $sql = 'SELECT MAX(id) AS total FROM datos_cabecera_electronica';
        return $this->select($sql);
    }
    //movimiento

    public function registrarMovimiento($movimiento, $accion, $cantidad, $stockActual, $idProducto, $id_usuario)
    {
        $sql = 'INSERT INTO inventario (movimiento, accion, cantidad, stock_actual, id_producto, id_usuario) VALUES (?,?,?,?,?,?)';
        $array = array($movimiento, $accion, $cantidad, $stockActual, $idProducto, $id_usuario);
        return $this->insertar($sql, $array);
    }

    public function getCaja($id_usuario)
    {
        $sql = "SELECT * FROM cajas WHERE estado = 1 AND id_usuario = $id_usuario";
        return $this->select($sql);
    }
    // $codigoPago va al final y con valor por defecto: las llamadas que no lo
    // pasan (facturacion automatica) siguen funcionando igual.
    public function registrarOrdenVenta($productos, $total, $fecha, $hora, $metodo, $descuento, $serie, $estado, $idCliente, $idusuario, $tipoPago, $codigoPago = null)
    {
        $sql = "INSERT INTO orden_venta (productos, total, fecha, hora, metodo,descuento, serie,estado, id_cliente, id_usuario,tipopago,codigo_pago) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)";
        $array = array($productos, $total, $fecha, $hora, $metodo, $descuento, $serie, $estado, $idCliente, $idusuario, $tipoPago, $codigoPago);
        return $this->insertar($sql, $array);
    }

    /**
     * Devuelve donde se uso ya un numero de comprobante, o null si esta libre.
     * Mira los tres sitios donde puede haber quedado registrado un pago:
     * facturas electronicas, ordenes de venta y abonos de credito.
     */
    public function getComprobanteUsado($codigo)
    {
        $sql = "SELECT 'FACTURA' AS origen, secuencial AS referencia, fecha
                FROM datos_cabecera_electronica WHERE codigo_pago = ?
                UNION ALL
                SELECT 'ORDEN DE VENTA', serie, fecha FROM orden_venta WHERE codigo_pago = ?
                UNION ALL
                SELECT 'ABONO', CONCAT('CREDITO #', id_credito), fecha FROM abonos WHERE codigo_pago = ?
                LIMIT 1";
        $data = $this->select($sql, array($codigo, $codigo, $codigo));
        return empty($data) ? null : $data;
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
        $idCliente,
        $codigoPago = null

    ) {
        $sql = "INSERT INTO datos_cabecera_electronica (fecha, orden_no, cliente, direccion,telefono, ruc,tipo_identificacion,
         correo,establecimiento,punto_emi,ruc_empresa,ambiente,razon_social,nombre_comercial,secuencial,
         direccion_matriz,obligado,totaldescuento,totalfactura,tipopago,estado,metodo,id_usuario,id_cliente,codigo_pago) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)";
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
            $idCliente,
            $codigoPago
        );
        return $this->insertar($sql, $array);
    }


    public function registrarDetalle($numSerieElectronica, $cantidad, $descripcion, $precio, $total, $iva, $codigo, $descuentoDetalle,$precio_pvp,$descuento, $idProducto)
    {
        $sql = 'INSERT INTO detalle_factura_electronica (orden_no, cantidad, item, precio_u,total, iva,codproducto,descuento,precio_pvp,por_descuento,id_producto) VALUES (?,?,?,?,?,?,?,?,?,?,?)';
        $array = array($numSerieElectronica, $cantidad, $descripcion, $precio, $total, $iva, $codigo, $descuentoDetalle,$precio_pvp,$descuento, $idProducto);
        return $this->insertar($sql, $array);
    }

    public function actualizarMesContrato($enero, $febrero, $marzo, $abril, $mayo, $junio, $julio, $agosto, $septiembre, $octubre, $noviembre, $diciembre, $idContrato)
    {
        $sql = "UPDATE mes_facturar SET enero= ?,febrero=?,marzo=?,abril=?,mayo=?,junio=?,julio=?,agosto=?,septiembre=?,octubre=?,noviembre=?,diciembre=? WHERE id_contrato = ?";
        $array = array($enero, $febrero, $marzo, $abril, $mayo, $junio, $julio, $agosto, $septiembre, $octubre, $noviembre, $diciembre, $idContrato);
        return $this->save($sql, $array);
    }
    public function actualizarMesContratoF($mes, $valor, $idContrato, $regla)
    {

        if ($regla == 'TODOS') {

            $sql = "UPDATE mes_facturar SET $mes = ?";
            $array = array($valor);
            return $this->save($sql, $array);
        } else {
            $sql = "UPDATE mes_facturar SET $mes = ? WHERE id_contrato = ?";
            $array = array($valor, $idContrato);
            return $this->save($sql, $array);
        }

    }
       public function actualizarMesContratoAnterior($mes, $valor, $idContrato, $regla)
    {

        if ($regla == 'TODOS') {

            $sql = "UPDATE mes_facturar SET $mes = ?";
            $array = array($valor);
            return $this->save($sql, $array);
        } else {
            $sql = "UPDATE mes_facturar SET $mes = ? WHERE id_contrato = ?";
            $array = array($valor, $idContrato);
            return $this->save($sql, $array);
        }

    }
    public function actualizarCorte($fecha, $fechaCorte, $nombre)
    {
        $sql = "INSERT INTO estado_corte (fecha,fecha_corte,nombre) VALUES (?,?,?)";
        $array = array($fecha, $fechaCorte, $nombre);
        return $this->insertar($sql, $array);
    }
    public function actualizarClaveAccesso($claveAccesso, $idVenta)
    {
        $sql = 'UPDATE datos_cabecera_electronica SET claveacceso = ? WHERE orden_no = ?';
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


    public function getDatosOrdenVenta($idOrdenVenta)
    {
        $sql = "SELECT total FROM orden_venta WHERE id = $idOrdenVenta";
        return $this->select($sql);
    }
    public function getDatosFacturas($idFactura)
    {
        $sql = "SELECT totalfactura AS total FROM datos_cabecera_electronica WHERE id = $idFactura";
        return $this->select($sql);
    }
    public function getDatosImprimirFacturas($id)
    {
        $sql = "SELECT dce.orden_no,dce.cliente,dce.totalfactura FROM datos_cabecera_electronica dce WHERE dce.orden_no= $id";
        return $this->select($sql);
    }
    public function getDatosImprimirOrdenes($id)
    {
        $sql = "SELECT ov.id,ov.serie,c.nombre,ov.total FROM orden_venta ov INNER JOIN clientes c ON c.id=ov.id_cliente WHERE ov.id= $id";
        return $this->select($sql);
    }
    public function getContratoFacturar($idContrato, $estado)
    {
        $sql = "SELECT c.id,c.productos,c.total,c.direccion,c.comentario,cl.id AS idCliente ,cl.nombre,c.estado,c.factura 
        FROM contratos c
         INNER JOIN clientes cl ON cl.id=c.id_cliente
          WHERE c.id= $idContrato AND c.estado = $estado";
        return $this->select($sql);
    }
    //de prueba
    public function getOrdenVenta($idOrdenVenta)
    {
        $sql = "SELECT ov.id,ov.productos,ov.total,ov.fecha,ov.hora,ov.descuento,ov.metodo,ov.serie,ov.estado, cl.identidad,cl.correo, cl.num_identidad, cl.nombre, cl.telefono, cl.direccion,CONCAT(u.nombre,' ',u.apellido) AS responsable FROM orden_venta ov 
        INNER JOIN usuarios u ON u.id=ov.id_usuario
        INNER JOIN clientes cl ON ov.id_cliente = cl.id WHERE ov.id = $idOrdenVenta";
        return $this->select($sql);
    }
    //consultas cron
public function getFacturasParaCorreo()
{
    $sql = "SELECT dce.*, cli.correo AS correo_cliente
            FROM datos_cabecera_electronica dce
            LEFT JOIN clientes cli ON cli.id = dce.id_cliente
            WHERE dce.estado_proceso = 1
              AND dce.sri_enviado = 1
              AND dce.correo_enviado = 0
              AND dce.claveacceso IS NOT NULL
              AND dce.claveacceso <> ''
            ORDER BY dce.fecha DESC, dce.id DESC
            LIMIT 50";
    return $this->selectAll($sql);
}

/**
  * Marca la factura como PENDIENTE de enviar el WhatsApp de "GRACIAS POR SU PAGO".
  * Solo la llama el cobro manual desde "Facturar Contratos": la facturacion
  * automatica mensual factura a todos (hayan pagado o no) y debe quedarse con
  * el valor por defecto (1 = no enviar nada).
  */
 public function marcarWhatsappPendiente($numSerie)
 {
     $sql = "UPDATE datos_cabecera_electronica
             SET whatsapp_enviado = 0
             WHERE orden_no = ?";
     return $this->save($sql, [$numSerie]);
 }

 /** Da por resuelto el WhatsApp de pago (enviado, o sin telefono al que enviarlo). */
 public function marcarWhatsappEnviado($numSerie)
 {
     $sql = "UPDATE datos_cabecera_electronica
             SET whatsapp_enviado = 1
             WHERE orden_no = ?";
     return $this->save($sql, [$numSerie]);
 }

 /**
  * Facturas de cobro manual ya AUTORIZADAS a las que todavia no se les envio el
  * WhatsApp de pago (el SRI no autorizo en el acto y lo hizo el cron despues).
  * La ventana de 3 dias acota los reintentos de un numero que falla siempre y
  * es una segunda barrera contra cualquier envio retroactivo masivo.
  */
 public function getFacturasParaWhatsapp()
 {
     $sql = "SELECT dce.orden_no, dce.cliente, dce.telefono, dce.claveacceso,
                    (SELECT dfe.item
                       FROM detalle_factura_electronica dfe
                      WHERE dfe.orden_no = dce.orden_no
                      ORDER BY dfe.id_tabla LIMIT 1) AS descripcion
             FROM datos_cabecera_electronica dce
             WHERE dce.whatsapp_enviado = 0
               AND dce.estado_proceso = 1
               AND dce.sri_enviado = 1
               AND dce.claveacceso IS NOT NULL
               AND dce.claveacceso <> ''
               AND dce.fecha >= DATE_SUB(CURDATE(), INTERVAL 3 DAY)
             ORDER BY dce.id DESC
             LIMIT 20";
     return $this->selectAll($sql);
 }

public function marcarCorreoEnviado($numSerie)
{
    $sql = "UPDATE datos_cabecera_electronica
            SET correo_enviado = 1
            WHERE orden_no = ?";
    return $this->save($sql, [$numSerie]);
}



}
