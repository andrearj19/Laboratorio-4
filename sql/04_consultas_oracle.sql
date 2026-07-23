-- ============================================================================
-- 04_CONSULTAS_ORACLE.SQL
-- Proyecto ILE - Base de Datos Avanzada - UTPL
--
-- Tres consultas analiticas complejas sobre el modelo RELACIONAL.
-- Cada una tiene su equivalente exacto en 05_consultas_mongo.js para poder
-- comparar resultados entre Oracle y MongoDB.
--
-- EJECUTAR COMO: usuario_ile
-- ============================================================================

SET LINESIZE 220
SET PAGESIZE 300
SET FEEDBACK OFF
SET SQLBLANKLINES ON

PROMPT
PROMPT ############################################################
PROMPT #  CONSULTA 1 - RENTABILIDAD POR CATEGORIA DE PRODUCTO     #
PROMPT #  4 tablas + GROUP BY + COUNT DISTINCT + 2 funciones      #
PROMPT #  analiticas (RATIO_TO_REPORT y RANK)                     #
PROMPT ############################################################

COLUMN categoria    FORMAT A24
COLUMN facturas     FORMAT 999G999
COLUMN unidades     FORMAT 999G999
COLUMN ingreso      FORMAT 999G999D99
COLUMN ticket_linea FORMAT 9G999D99
COLUMN pct_total    FORMAT 990D99
COLUMN puesto       FORMAT 99

SELECT cat.nombre                                            AS categoria,
       COUNT(DISTINCT v.id_venta)                            AS facturas,
       SUM(dv.cantidad)                                      AS unidades,
       SUM(dv.subtotal)                                      AS ingreso,
       ROUND(AVG(dv.subtotal), 2)                            AS ticket_linea,
       ROUND(RATIO_TO_REPORT(SUM(dv.subtotal)) OVER () * 100, 2) AS pct_total,
       RANK() OVER (ORDER BY SUM(dv.subtotal) DESC)          AS puesto
  FROM venta          v
  JOIN detalle_venta  dv  ON dv.id_venta    = v.id_venta
  JOIN producto       p   ON p.id_producto  = dv.id_producto
  JOIN categoria      cat ON cat.id_categoria = p.id_categoria
 GROUP BY cat.nombre
 ORDER BY ingreso DESC;

PROMPT
PROMPT ############################################################
PROMPT #  CONSULTA 2 - TOP 10 CLIENTES Y SU PRODUCTO ESTRELLA     #
PROMPT #  2 CTE + ROW_NUMBER particionado + JOIN entre CTE        #
PROMPT #  (el producto mas comprado por cada cliente)             #
PROMPT ############################################################

COLUMN cliente           FORMAT A28
COLUMN cedula            FORMAT A11
COLUMN facturas          FORMAT 9G999
COLUMN total_facturado   FORMAT 99G999D99
COLUMN ticket_promedio   FORMAT 9G999D99
COLUMN ultima_compra     FORMAT A12
COLUMN producto_estrella FORMAT A30
COLUMN uds               FORMAT 9G999

WITH resumen_cliente AS (
  SELECT c.id_cliente,
         c.nombres || ' ' || c.apellidos AS cliente,
         c.cedula,
         COUNT(DISTINCT v.id_venta)      AS facturas,
         SUM(dv.subtotal)                AS total_facturado,
         MAX(v.fecha)                    AS ultima_compra
    FROM cliente        c
    JOIN venta          v  ON v.id_cliente = c.id_cliente
    JOIN detalle_venta  dv ON dv.id_venta  = v.id_venta
   GROUP BY c.id_cliente, c.nombres, c.apellidos, c.cedula
),
preferencia AS (
  SELECT id_cliente, producto, unidades,
         ROW_NUMBER() OVER (PARTITION BY id_cliente
                            ORDER BY unidades DESC, producto) AS rn
    FROM (SELECT v.id_cliente,
                 p.nombre        AS producto,
                 SUM(dv.cantidad) AS unidades
            FROM venta         v
            JOIN detalle_venta dv ON dv.id_venta   = v.id_venta
            JOIN producto      p  ON p.id_producto = dv.id_producto
           GROUP BY v.id_cliente, p.nombre)
)
SELECT r.cliente,
       r.cedula,
       r.facturas,
       r.total_facturado,
       ROUND(r.total_facturado / r.facturas, 2)   AS ticket_promedio,
       TO_CHAR(r.ultima_compra, 'DD/MM/YYYY')     AS ultima_compra,
       pr.producto                                AS producto_estrella,
       pr.unidades                                AS uds
  FROM resumen_cliente r
  JOIN preferencia     pr ON pr.id_cliente = r.id_cliente AND pr.rn = 1
 ORDER BY r.total_facturado DESC
 FETCH FIRST 10 ROWS ONLY;

PROMPT
PROMPT ############################################################
PROMPT #  CONSULTA 3 - EFICIENCIA DE PLANTA POR MES Y OPERARIO    #
PROMPT #  Top 3 de cada mes por consumo de materia prima por      #
PROMPT #  unidad producida. CTE previa para evitar el fan-out del #
PROMPT #  JOIN 1:N con detalle_produccion + RANK particionado     #
PROMPT ############################################################

COLUMN mes            FORMAT A9
COLUMN empleado       FORMAT A32
COLUMN cargo          FORMAT A28
COLUMN lotes          FORMAT 999
COLUMN unidades       FORMAT 999G999
COLUMN kg_mp          FORMAT 99G999D99
COLUMN kg_x_unidad    FORMAT 90D9999
COLUMN puesto         FORMAT 99

WITH lote AS (
  -- se agrega el consumo ANTES de unir con la cabecera: si se hiciera el JOIN
  -- directo, cantidad_producida se sumaria tantas veces como materias tenga
  -- el lote (fan-out) y el indicador saldria inflado
  SELECT pr.id_produccion,
         pr.fecha,
         pr.id_empleado,
         pr.cantidad_producida,
         (SELECT SUM(d.cantidad_utilizada)
            FROM detalle_produccion d
           WHERE d.id_produccion = pr.id_produccion) AS kg_mp
    FROM produccion pr
),
metrica AS (
  SELECT TO_CHAR(l.fecha, 'YYYY-MM')          AS mes,
         e.nombre                             AS empleado,
         e.cargo                              AS cargo,
         COUNT(*)                             AS lotes,
         SUM(l.cantidad_producida)            AS unidades,
         ROUND(SUM(l.kg_mp), 2)               AS kg_mp,
         ROUND(SUM(l.kg_mp) / SUM(l.cantidad_producida), 4) AS kg_x_unidad
    FROM lote     l
    JOIN empleado e ON e.id_empleado = l.id_empleado
   GROUP BY TO_CHAR(l.fecha, 'YYYY-MM'), e.nombre, e.cargo
)
SELECT mes, empleado, cargo, lotes, unidades, kg_mp, kg_x_unidad, puesto
  FROM (SELECT m.*,
               RANK() OVER (PARTITION BY mes ORDER BY kg_x_unidad) AS puesto
          FROM metrica m)
 WHERE puesto <= 3
 ORDER BY mes, puesto;

SET FEEDBACK ON
