-- ============================================================================
-- 02_AUDITORIA_CONSISTENCIA.SQL
-- Proyecto ILE - Base de Datos Avanzada - UTPL
--
-- Bateria de 24 chequeos de consistencia sobre el esquema USUARIO_ILE.
-- Cada chequeo devuelve el numero de filas defectuosas: el resultado esperado
-- es 0 en todos los casos. La columna VEREDICTO lo resume en OK / REVISAR.
--
-- EJECUTAR COMO: usuario_ile
-- ============================================================================

SET LINESIZE 200
SET PAGESIZE 300
SET FEEDBACK OFF
SET SQLBLANKLINES ON

COLUMN grupo     FORMAT A14
COLUMN chequeo   FORMAT A56
COLUMN malas     FORMAT 999G999
COLUMN veredicto FORMAT A9

PROMPT
PROMPT ############################################################
PROMPT #   AUDITORIA DE CONSISTENCIA - ESQUEMA USUARIO_ILE        #
PROMPT ############################################################
PROMPT

WITH chequeos AS (
  -- ---------- 1. INTEGRIDAD REFERENCIAL (huerfanos)
  SELECT 1 orden, 'Referencial' grupo, 'PRODUCTO con categoria inexistente' chequeo,
         COUNT(*) malas FROM producto p
   WHERE NOT EXISTS (SELECT 1 FROM categoria c WHERE c.id_categoria = p.id_categoria)
  UNION ALL
  SELECT 2, 'Referencial', 'COMPRA con proveedor inexistente', COUNT(*) FROM compra c
   WHERE NOT EXISTS (SELECT 1 FROM proveedor v WHERE v.id_proveedor = c.id_proveedor)
  UNION ALL
  SELECT 3, 'Referencial', 'VENTA con cliente inexistente', COUNT(*) FROM venta v
   WHERE NOT EXISTS (SELECT 1 FROM cliente c WHERE c.id_cliente = v.id_cliente)
  UNION ALL
  SELECT 4, 'Referencial', 'DETALLE_COMPRA con compra o materia inexistente', COUNT(*)
    FROM detalle_compra d
   WHERE NOT EXISTS (SELECT 1 FROM compra c WHERE c.id_compra = d.id_compra)
      OR NOT EXISTS (SELECT 1 FROM materia_prima m WHERE m.id_materia = d.id_materia)
  UNION ALL
  SELECT 5, 'Referencial', 'DETALLE_VENTA con venta o producto inexistente', COUNT(*)
    FROM detalle_venta d
   WHERE NOT EXISTS (SELECT 1 FROM venta v WHERE v.id_venta = d.id_venta)
      OR NOT EXISTS (SELECT 1 FROM producto p WHERE p.id_producto = d.id_producto)
  UNION ALL
  SELECT 6, 'Referencial', 'PRODUCCION con empleado o producto inexistente', COUNT(*)
    FROM produccion pr
   WHERE NOT EXISTS (SELECT 1 FROM empleado e WHERE e.id_empleado = pr.id_empleado)
      OR NOT EXISTS (SELECT 1 FROM producto p WHERE p.id_producto = pr.id_producto)
  UNION ALL
  SELECT 7, 'Referencial', 'DETALLE_PRODUCCION con lote o materia inexistente', COUNT(*)
    FROM detalle_produccion d
   WHERE NOT EXISTS (SELECT 1 FROM produccion p WHERE p.id_produccion = d.id_produccion)
      OR NOT EXISTS (SELECT 1 FROM materia_prima m WHERE m.id_materia = d.id_materia)

  -- ---------- 2. COMPLETITUD (cabeceras sin detalle)
  UNION ALL
  SELECT 8, 'Completitud', 'COMPRA sin ninguna linea de detalle', COUNT(*) FROM compra c
   WHERE NOT EXISTS (SELECT 1 FROM detalle_compra d WHERE d.id_compra = c.id_compra)
  UNION ALL
  SELECT 9, 'Completitud', 'VENTA sin ninguna linea de detalle', COUNT(*) FROM venta v
   WHERE NOT EXISTS (SELECT 1 FROM detalle_venta d WHERE d.id_venta = v.id_venta)
  UNION ALL
  SELECT 10, 'Completitud', 'PRODUCCION sin consumo de materia prima', COUNT(*) FROM produccion p
   WHERE NOT EXISTS (SELECT 1 FROM detalle_produccion d WHERE d.id_produccion = p.id_produccion)

  -- ---------- 3. CUADRE ARITMETICO
  UNION ALL
  SELECT 11, 'Aritmetica', 'DETALLE_COMPRA: subtotal <> cantidad * precio', COUNT(*)
    FROM detalle_compra WHERE ABS(subtotal - ROUND(cantidad * precio_unitario, 2)) > 0.01
  UNION ALL
  SELECT 12, 'Aritmetica', 'DETALLE_VENTA: subtotal <> cantidad * precio', COUNT(*)
    FROM detalle_venta WHERE ABS(subtotal - ROUND(cantidad * precio_unitario, 2)) > 0.01
  UNION ALL
  SELECT 13, 'Aritmetica', 'COMPRA.total <> suma de sus detalles', COUNT(*) FROM (
    SELECT c.id_compra FROM compra c
      JOIN detalle_compra d ON d.id_compra = c.id_compra
     GROUP BY c.id_compra, c.total HAVING ABS(c.total - SUM(d.subtotal)) > 0.01)
  UNION ALL
  SELECT 14, 'Aritmetica', 'VENTA.total <> suma de sus detalles', COUNT(*) FROM (
    SELECT v.id_venta FROM venta v
      JOIN detalle_venta d ON d.id_venta = v.id_venta
     GROUP BY v.id_venta, v.total HAVING ABS(v.total - SUM(d.subtotal)) > 0.01)
  UNION ALL
  SELECT 15, 'Aritmetica', 'DETALLE_VENTA: precio cobrado <> precio de catalogo', COUNT(*)
    FROM detalle_venta d JOIN producto p ON p.id_producto = d.id_producto
   WHERE d.precio_unitario <> p.precio

  -- ---------- 4. UNICIDAD
  UNION ALL
  SELECT 16, 'Unicidad', 'CEDULA duplicada en CLIENTE', COUNT(*) FROM (
    SELECT cedula FROM cliente GROUP BY cedula HAVING COUNT(*) > 1)
  UNION ALL
  SELECT 17, 'Unicidad', 'RUC duplicado en PROVEEDOR', COUNT(*) FROM (
    SELECT ruc FROM proveedor GROUP BY ruc HAVING COUNT(*) > 1)
  UNION ALL
  SELECT 18, 'Unicidad', 'NOMBRE duplicado en PRODUCTO', COUNT(*) FROM (
    SELECT nombre FROM producto GROUP BY nombre HAVING COUNT(*) > 1)
  UNION ALL
  SELECT 19, 'Unicidad', 'Producto repetido dentro de una misma VENTA', COUNT(*) FROM (
    SELECT id_venta, id_producto FROM detalle_venta
     GROUP BY id_venta, id_producto HAVING COUNT(*) > 1)

  -- ---------- 5. DOMINIO
  UNION ALL
  SELECT 20, 'Dominio', 'Importes o cantidades <= 0 en cualquier tabla', (
    (SELECT COUNT(*) FROM producto WHERE precio <= 0 OR stock < 0)
  + (SELECT COUNT(*) FROM materia_prima WHERE stock < 0)
  + (SELECT COUNT(*) FROM venta WHERE total <= 0)
  + (SELECT COUNT(*) FROM compra WHERE total <= 0)
  + (SELECT COUNT(*) FROM detalle_venta WHERE cantidad <= 0 OR precio_unitario <= 0)
  + (SELECT COUNT(*) FROM detalle_compra WHERE cantidad <= 0 OR precio_unitario <= 0)
  + (SELECT COUNT(*) FROM produccion WHERE cantidad_producida <= 0)
  + (SELECT COUNT(*) FROM detalle_produccion WHERE cantidad_utilizada <= 0)) FROM dual
  UNION ALL
  SELECT 21, 'Dominio', 'CEDULA de cliente con longitud <> 10', COUNT(*)
    FROM cliente WHERE LENGTH(cedula) <> 10
  UNION ALL
  SELECT 22, 'Dominio', 'RUC de proveedor con longitud <> 13', COUNT(*)
    FROM proveedor WHERE LENGTH(ruc) <> 13

  -- ---------- 6. COHERENCIA TEMPORAL
  UNION ALL
  SELECT 23, 'Temporal', 'Transacciones con fecha futura', (
    (SELECT COUNT(*) FROM venta WHERE fecha > SYSDATE)
  + (SELECT COUNT(*) FROM compra WHERE fecha > SYSDATE)
  + (SELECT COUNT(*) FROM produccion WHERE fecha > SYSDATE)) FROM dual
  UNION ALL
  SELECT 24, 'Temporal', 'Transacciones fuera del ejercicio 2026', (
    (SELECT COUNT(*) FROM venta WHERE fecha NOT BETWEEN DATE '2026-01-01' AND DATE '2026-12-31')
  + (SELECT COUNT(*) FROM compra WHERE fecha NOT BETWEEN DATE '2026-01-01' AND DATE '2026-12-31')
  + (SELECT COUNT(*) FROM produccion WHERE fecha NOT BETWEEN DATE '2026-01-01' AND DATE '2026-12-31')) FROM dual
)
SELECT grupo, chequeo, malas,
       CASE WHEN malas = 0 THEN 'OK' ELSE 'REVISAR' END AS veredicto
  FROM chequeos ORDER BY orden;

PROMPT
PROMPT ==== VOLUMETRIA FINAL DEL ESQUEMA ====
COLUMN tabla FORMAT A22
COLUMN filas FORMAT 999G999
SELECT 'CATEGORIA' tabla, COUNT(*) filas FROM categoria
UNION ALL SELECT 'CLIENTE',            COUNT(*) FROM cliente
UNION ALL SELECT 'PROVEEDOR',          COUNT(*) FROM proveedor
UNION ALL SELECT 'EMPLEADO',           COUNT(*) FROM empleado
UNION ALL SELECT 'MATERIA_PRIMA',      COUNT(*) FROM materia_prima
UNION ALL SELECT 'PRODUCTO',           COUNT(*) FROM producto
UNION ALL SELECT 'COMPRA',             COUNT(*) FROM compra
UNION ALL SELECT 'DETALLE_COMPRA',     COUNT(*) FROM detalle_compra
UNION ALL SELECT 'VENTA',              COUNT(*) FROM venta
UNION ALL SELECT 'DETALLE_VENTA',      COUNT(*) FROM detalle_venta
UNION ALL SELECT 'PRODUCCION',         COUNT(*) FROM produccion
UNION ALL SELECT 'DETALLE_PRODUCCION', COUNT(*) FROM detalle_produccion
ORDER BY 1;

PROMPT
PROMPT ==== OBJETOS INVALIDOS (esperado: ninguno) ====
SELECT object_type, object_name, status FROM user_objects WHERE status <> 'VALID';

PROMPT
PROMPT ==== RESTRICCIONES ACTIVAS ====
COLUMN tipo FORMAT A28
SELECT CASE constraint_type WHEN 'P' THEN 'PRIMARY KEY'
                            WHEN 'R' THEN 'FOREIGN KEY'
                            WHEN 'U' THEN 'UNIQUE'
                            WHEN 'C' THEN 'CHECK / NOT NULL' END AS tipo,
       COUNT(*) AS cantidad
  FROM user_constraints WHERE status = 'ENABLED'
 GROUP BY constraint_type ORDER BY 1;

SET FEEDBACK ON
