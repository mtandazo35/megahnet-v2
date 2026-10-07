-- 010 - Alinear el detalle de la factura electronica con los limites del SRI
--
-- Motivo (rutanet, 2026-10-02 y 2026-10-07): dos facturas de un mismo cliente
-- quedaron con cabecera y CERO lineas porque el INSERT del detalle murio con
-- "Data too long for column 'item'". El XML salio con <detalles></detalles> y el
-- SRI lo devolvio con el error 35 "ARCHIVO NO CUMPLE ESTRUCTURA XML".
-- Una tercera factura se cayo por un codigo de producto de 28 caracteres cuando
-- el SRI admite 25 en `codigoPrincipal`.
--
-- La ficha tecnica del SRI acepta `descripcion` de hasta 300 caracteres: la
-- columna estaba en 250, mas estrecha que el propio SRI.
--
-- Idempotente: se puede aplicar las veces que sea.

-- 1) La descripcion de la linea, al maximo que admite el SRI.
ALTER TABLE detalle_factura_electronica
    MODIFY item VARCHAR(300) NULL;

-- 2) Codigos de producto mas largos de lo que acepta el SRI.
--    Se recortan a 25 en las DOS tablas, con el mismo recorte, porque
--    VentasModel::getVentaElectronica une productos con el detalle por
--    `productos.codigo = detalle_factura_electronica.codproducto`: si se
--    recortara solo una, esa union dejaria de encontrar el producto y la
--    anulacion de facturas dejaria de devolver el stock.
UPDATE detalle_factura_electronica
   SET codproducto = LEFT(codproducto, 25)
 WHERE CHAR_LENGTH(codproducto) > 25;

UPDATE productos
   SET codigo = LEFT(codigo, 25)
 WHERE CHAR_LENGTH(codigo) > 25;
