<?php
class Query extends Conexion
{
    private $pdo, $con;

    public function __construct()
    {
        $this->pdo = new Conexion();
        $this->con = $this->pdo->conectar();
    }

    // === Devuelve un solo registro ===
    public function select($sql, $array = [])
    {
        $result = $this->con->prepare($sql);
        $result->execute($array);
        return $result->fetch(PDO::FETCH_ASSOC);
    }

    // === Devuelve varios registros ===
    public function selectAll($sql, $array = [])
    {
        $result = $this->con->prepare($sql);
        $result->execute($array);
        return $result->fetchAll(PDO::FETCH_ASSOC);
    }

    // === Transacciones =========================================================
    // Hacen falta para que una cabecera y su detalle entren o no entren juntos.
    // Sin esto, si el INSERT del detalle falla a mitad (p.ej. una descripcion mas
    // larga que la columna), la cabecera ya quedo guardada y nace una factura con
    // total pero sin lineas: el XML sale con <detalles></detalles> y el SRI la
    // devuelve con el error 35. Paso en rutanet el 2026-10-02 y el 2026-10-07.
    //
    // Cada modelo tiene su propia conexion (Query::__construct crea una), asi que
    // la transaccion cubre todo lo que se haga a traves del MISMO modelo.
    public function iniciarTransaccion()
    {
        if ($this->con->inTransaction()) {
            return false; // ya hay una abierta; no se anidan
        }
        return $this->con->beginTransaction();
    }

    public function confirmar()
    {
        return $this->con->inTransaction() ? $this->con->commit() : false;
    }

    public function revertir()
    {
        return $this->con->inTransaction() ? $this->con->rollBack() : false;
    }

    // === Inserta un registro y devuelve el ID ===
    public function insertar($sql, $array)
    {
        $result = $this->con->prepare($sql);
        $data = $result->execute($array);
        if ($data) {
            $res = $this->con->lastInsertId();
        } else {
            $res = 0;
        }
        return $res;
    }

    // === Ejecuta UPDATE o DELETE ===
    public function save($sql, $array)
    {
        $result = $this->con->prepare($sql);
        $data = $result->execute($array);
        if ($data) {
            $res = 1;
        } else {
            $res = 0;
        }
        return $res;
    }
    public function select2($sql, $params = [])
    {
        try {
            $stmt = $this->con->prepare($sql);
            $stmt->execute($params);
            return $stmt->fetchAll(PDO::FETCH_ASSOC);
        } catch (PDOException $e) {
            die("ERROR EN SELECT: " . $e->getMessage());
        }
    }
       public function selectAllPrepared($sql, $params)
    {
        $result = $this->con->prepare($sql);
        $result->execute($params);
        return $result->fetchAll(PDO::FETCH_ASSOC);
    }
}
?>