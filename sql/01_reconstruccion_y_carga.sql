-- ============================================================================
-- 01_RECONSTRUCCION_Y_CARGA.SQL
-- Proyecto ILE - Base de Datos Avanzada - UTPL
--
-- MOTIVO:
--   El respaldo RESPALDO_ILE_TABLAS.DMP es un export PARCIAL: solo contiene
--   6 tablas (CLIENTE, PROVEEDOR, PRODUCTO, MATERIA_PRIMA, COMPRA, VENTA).
--   Faltan CATEGORIA, EMPLEADO, DETALLE_COMPRA, DETALLE_VENTA, PRODUCCION y
--   DETALLE_PRODUCCION. Por eso al importar fallo el FK_PRODUCTO_CATEGORIA
--   (ORA-00942) y las 3 vistas de negocio no se pueden compilar.
--
-- QUE HACE ESTE SCRIPT:
--   1. Crea las 6 tablas faltantes con sus PK, FK, CHECK y secuencias.
--   2. Carga CATEGORIA y EMPLEADO (datos maestros).
--   3. Genera los detalles transaccionales de forma DETERMINISTA (semilla fija)
--      respetando la integridad referencial.
--   4. Recalcula COMPRA.TOTAL y VENTA.TOTAL como la suma exacta de sus
--      detalles, de modo que cabecera y detalle cuadren al centavo.
--   5. Cierra el FK_PRODUCTO_CATEGORIA que quedo pendiente en la importacion.
--
-- EJECUTAR COMO: usuario_ile  (conexion ILE_XEPDB1 en SQL Developer)
-- ============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

-- ---------------------------------------------------------------------------
-- PASO 0: limpieza idempotente (permite re-ejecutar el script sin errores)
-- ---------------------------------------------------------------------------
BEGIN
  FOR t IN (SELECT table_name FROM user_tables
             WHERE table_name IN ('DETALLE_PRODUCCION','PRODUCCION',
                                  'DETALLE_VENTA','DETALLE_COMPRA',
                                  'EMPLEADO','CATEGORIA')) LOOP
    EXECUTE IMMEDIATE 'DROP TABLE '||t.table_name||' CASCADE CONSTRAINTS PURGE';
  END LOOP;
  FOR s IN (SELECT sequence_name FROM user_sequences
             WHERE sequence_name LIKE 'SEQ_%') LOOP
    EXECUTE IMMEDIATE 'DROP SEQUENCE '||s.sequence_name;
  END LOOP;
  -- si el FK a categoria quedo a medias de una corrida anterior
  FOR c IN (SELECT constraint_name FROM user_constraints
             WHERE constraint_name = 'FK_PRODUCTO_CATEGORIA') LOOP
    EXECUTE IMMEDIATE 'ALTER TABLE producto DROP CONSTRAINT '||c.constraint_name;
  END LOOP;
END;
/

-- ---------------------------------------------------------------------------
-- PASO 1: DDL de las tablas faltantes
-- ---------------------------------------------------------------------------

-- 1.1 CATEGORIA: clasificacion comercial del catalogo de productos
CREATE TABLE categoria (
  id_categoria  NUMBER(10)     NOT NULL,
  nombre        VARCHAR2(60)   NOT NULL,
  descripcion   VARCHAR2(200)
) TABLESPACE ts_ile_datos;

ALTER TABLE categoria ADD CONSTRAINT pk_categoria
  PRIMARY KEY (id_categoria) USING INDEX TABLESPACE ts_ile_indices;
ALTER TABLE categoria ADD CONSTRAINT uk_categoria_nombre
  UNIQUE (nombre) USING INDEX TABLESPACE ts_ile_indices;

-- 1.2 EMPLEADO: personal de planta que ejecuta los lotes de produccion
CREATE TABLE empleado (
  id_empleado    NUMBER(10)    NOT NULL,
  nombre         VARCHAR2(80)  NOT NULL,
  cedula         VARCHAR2(10)  NOT NULL,
  cargo          VARCHAR2(60)  NOT NULL,
  fecha_ingreso  DATE          DEFAULT SYSDATE NOT NULL
) TABLESPACE ts_ile_datos;

ALTER TABLE empleado ADD CONSTRAINT pk_empleado
  PRIMARY KEY (id_empleado) USING INDEX TABLESPACE ts_ile_indices;
ALTER TABLE empleado ADD CONSTRAINT uk_empleado_cedula
  UNIQUE (cedula) USING INDEX TABLESPACE ts_ile_indices;
ALTER TABLE empleado ADD CONSTRAINT ck_empleado_cedula
  CHECK (LENGTH(cedula) = 10);

-- 1.3 DETALLE_COMPRA: lineas de la factura de compra de materia prima
CREATE TABLE detalle_compra (
  id_detalle_compra NUMBER(10)   NOT NULL,
  id_compra         NUMBER(10)   NOT NULL,
  id_materia        NUMBER(10)   NOT NULL,
  cantidad          NUMBER(10,2) NOT NULL,
  precio_unitario   NUMBER(10,2) NOT NULL,
  subtotal          NUMBER(12,2) NOT NULL
) TABLESPACE ts_ile_datos;

ALTER TABLE detalle_compra ADD CONSTRAINT pk_detalle_compra
  PRIMARY KEY (id_detalle_compra) USING INDEX TABLESPACE ts_ile_indices;
ALTER TABLE detalle_compra ADD CONSTRAINT fk_dcompra_compra
  FOREIGN KEY (id_compra) REFERENCES compra (id_compra);
ALTER TABLE detalle_compra ADD CONSTRAINT fk_dcompra_materia
  FOREIGN KEY (id_materia) REFERENCES materia_prima (id_materia);
ALTER TABLE detalle_compra ADD CONSTRAINT uk_dcompra_linea
  UNIQUE (id_compra, id_materia) USING INDEX TABLESPACE ts_ile_indices;
ALTER TABLE detalle_compra ADD CONSTRAINT ck_dcompra_cantidad
  CHECK (cantidad > 0);
ALTER TABLE detalle_compra ADD CONSTRAINT ck_dcompra_precio
  CHECK (precio_unitario > 0);

-- 1.4 DETALLE_VENTA: lineas de la factura de venta al cliente
CREATE TABLE detalle_venta (
  id_detalle_venta NUMBER(10)   NOT NULL,
  id_venta         NUMBER(10)   NOT NULL,
  id_producto      NUMBER(10)   NOT NULL,
  cantidad         NUMBER(10)   NOT NULL,
  precio_unitario  NUMBER(10,2) NOT NULL,
  subtotal         NUMBER(12,2) NOT NULL
) TABLESPACE ts_ile_datos;

ALTER TABLE detalle_venta ADD CONSTRAINT pk_detalle_venta
  PRIMARY KEY (id_detalle_venta) USING INDEX TABLESPACE ts_ile_indices;
ALTER TABLE detalle_venta ADD CONSTRAINT fk_dventa_venta
  FOREIGN KEY (id_venta) REFERENCES venta (id_venta);
ALTER TABLE detalle_venta ADD CONSTRAINT fk_dventa_producto
  FOREIGN KEY (id_producto) REFERENCES producto (id_producto);
ALTER TABLE detalle_venta ADD CONSTRAINT uk_dventa_linea
  UNIQUE (id_venta, id_producto) USING INDEX TABLESPACE ts_ile_indices;
ALTER TABLE detalle_venta ADD CONSTRAINT ck_dventa_cantidad
  CHECK (cantidad > 0);
ALTER TABLE detalle_venta ADD CONSTRAINT ck_dventa_precio
  CHECK (precio_unitario > 0);

-- 1.5 PRODUCCION: cabecera del lote fabricado en planta
CREATE TABLE produccion (
  id_produccion      NUMBER(10) NOT NULL,
  fecha              DATE       DEFAULT SYSDATE NOT NULL,
  id_empleado        NUMBER(10) NOT NULL,
  id_producto        NUMBER(10) NOT NULL,
  cantidad_producida NUMBER(10) NOT NULL
) TABLESPACE ts_ile_datos;

ALTER TABLE produccion ADD CONSTRAINT pk_produccion
  PRIMARY KEY (id_produccion) USING INDEX TABLESPACE ts_ile_indices;
ALTER TABLE produccion ADD CONSTRAINT fk_produccion_empleado
  FOREIGN KEY (id_empleado) REFERENCES empleado (id_empleado);
ALTER TABLE produccion ADD CONSTRAINT fk_produccion_producto
  FOREIGN KEY (id_producto) REFERENCES producto (id_producto);
ALTER TABLE produccion ADD CONSTRAINT ck_produccion_cantidad
  CHECK (cantidad_producida > 0);

-- 1.6 DETALLE_PRODUCCION: consumo de materia prima por lote
CREATE TABLE detalle_produccion (
  id_detalle_produccion NUMBER(10)   NOT NULL,
  id_produccion         NUMBER(10)   NOT NULL,
  id_materia            NUMBER(10)   NOT NULL,
  cantidad_utilizada    NUMBER(10,2) NOT NULL
) TABLESPACE ts_ile_datos;

ALTER TABLE detalle_produccion ADD CONSTRAINT pk_detalle_produccion
  PRIMARY KEY (id_detalle_produccion) USING INDEX TABLESPACE ts_ile_indices;
ALTER TABLE detalle_produccion ADD CONSTRAINT fk_dprod_produccion
  FOREIGN KEY (id_produccion) REFERENCES produccion (id_produccion);
ALTER TABLE detalle_produccion ADD CONSTRAINT fk_dprod_materia
  FOREIGN KEY (id_materia) REFERENCES materia_prima (id_materia);
ALTER TABLE detalle_produccion ADD CONSTRAINT uk_dprod_linea
  UNIQUE (id_produccion, id_materia) USING INDEX TABLESPACE ts_ile_indices;
ALTER TABLE detalle_produccion ADD CONSTRAINT ck_dprod_cantidad
  CHECK (cantidad_utilizada > 0);

-- 1.7 Indices de apoyo sobre las FK (evitan bloqueos y aceleran los JOIN)
CREATE INDEX idx_fk_dcompra_compra  ON detalle_compra (id_compra)     TABLESPACE ts_ile_indices;
CREATE INDEX idx_fk_dcompra_materia ON detalle_compra (id_materia)    TABLESPACE ts_ile_indices;
CREATE INDEX idx_fk_dventa_venta    ON detalle_venta (id_venta)       TABLESPACE ts_ile_indices;
CREATE INDEX idx_fk_dventa_prod     ON detalle_venta (id_producto)    TABLESPACE ts_ile_indices;
CREATE INDEX idx_fk_prod_emp        ON produccion (id_empleado)       TABLESPACE ts_ile_indices;
CREATE INDEX idx_fk_prod_producto   ON produccion (id_producto)       TABLESPACE ts_ile_indices;
CREATE INDEX idx_fk_dprod_prod      ON detalle_produccion (id_produccion) TABLESPACE ts_ile_indices;
CREATE INDEX idx_fk_dprod_materia   ON detalle_produccion (id_materia)    TABLESPACE ts_ile_indices;

-- 1.8 Secuencias para altas futuras
CREATE SEQUENCE seq_detalle_compra     START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE seq_detalle_venta      START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE seq_produccion         START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE seq_detalle_produccion START WITH 1 INCREMENT BY 1 NOCACHE;

-- ---------------------------------------------------------------------------
-- PASO 2: carga de datos maestros
-- ---------------------------------------------------------------------------

-- 2.1 CATEGORIA: los 7 id_categoria ya referenciados por PRODUCTO (1..7)
INSERT INTO categoria VALUES (1,'Especias Molidas','Especias procesadas y pulverizadas listas para uso directo');
INSERT INTO categoria VALUES (2,'Especias Enteras','Especias comercializadas en grano, rama o pieza entera');
INSERT INTO categoria VALUES (3,'Hierbas Aromaticas','Hierbas deshidratadas para sazonar e infusionar');
INSERT INTO categoria VALUES (4,'Alinos y Sazonadores','Mezclas y pastas condimentadas de preparacion propia');
INSERT INTO categoria VALUES (5,'Sales Condimentadas','Sales puras y saborizadas para mesa y parrilla');
INSERT INTO categoria VALUES (6,'Infusiones y Bebidas','Sobres de te, horchata e infusiones tradicionales');
INSERT INTO categoria VALUES (7,'Reposteria y Aditivos','Insumos complementarios para panaderia y reposteria');

-- 2.2 EMPLEADO: nomina de planta
INSERT INTO empleado VALUES (1 ,'Jorge Anibal Cueva Jaramillo'   ,'1104582301','Jefe de Planta'            ,DATE '2019-03-04');
INSERT INTO empleado VALUES (2 ,'Maria Fernanda Ordonez Loaiza'  ,'1103998774','Supervisora de Produccion' ,DATE '2020-01-15');
INSERT INTO empleado VALUES (3 ,'Luis Alberto Chamba Guaman'     ,'1105412098','Operador de Molienda'      ,DATE '2020-07-22');
INSERT INTO empleado VALUES (4 ,'Rosa Elena Sarango Quezada'     ,'1104773215','Operadora de Envasado'     ,DATE '2021-02-08');
INSERT INTO empleado VALUES (5 ,'Carlos Andres Tandazo Riofrio'  ,'1105980043','Operador de Molienda'      ,DATE '2021-05-30');
INSERT INTO empleado VALUES (6 ,'Diana Carolina Vega Montoya'    ,'1103446721','Tecnica de Control Calidad',DATE '2021-09-13');
INSERT INTO empleado VALUES (7 ,'Segundo Manuel Japon Curipoma'  ,'1104110956','Operador de Secado'        ,DATE '2022-01-10');
INSERT INTO empleado VALUES (8 ,'Nube Patricia Armijos Torres'   ,'1105337882','Operadora de Envasado'     ,DATE '2022-04-19');
INSERT INTO empleado VALUES (9 ,'Edwin Patricio Gonzalez Lopez'  ,'1104660314','Tecnico de Mantenimiento'  ,DATE '2022-11-07');
INSERT INTO empleado VALUES (10,'Jessica Alexandra Pauta Vivanco','1105774129','Supervisora de Bodega'     ,DATE '2023-03-01');
INSERT INTO empleado VALUES (11,'Byron Fabian Robles Encalada'   ,'1104028567','Operador de Mezclado'      ,DATE '2023-08-16');
INSERT INTO empleado VALUES (12,'Silvia Marlene Camacho Ruiz'    ,'1105219640','Operadora de Etiquetado'   ,DATE '2024-02-05');

COMMIT;

-- ---------------------------------------------------------------------------
-- PASO 3: generacion determinista de los detalles transaccionales
--         DBMS_RANDOM.SEED fija la semilla => el resultado es reproducible
-- ---------------------------------------------------------------------------
DECLARE
  v_id       NUMBER;
  v_lineas   PLS_INTEGER;
  v_cant     NUMBER;
  v_precio   NUMBER;
  v_sub      NUMBER;
  v_total    NUMBER;
  v_filas    PLS_INTEGER := 0;

  -- costo referencial por kilogramo de cada materia prima
  FUNCTION costo_kg (p_id NUMBER) RETURN NUMBER IS
  BEGIN
    RETURN CASE p_id
             WHEN 1  THEN 4.50   -- Oregano seco
             WHEN 2  THEN 5.20   -- Comino en grano
             WHEN 3  THEN 6.10   -- Ajo deshidratado
             WHEN 4  THEN 9.80   -- Pimienta negra
             WHEN 5  THEN 0.65   -- Sal marina
             WHEN 6  THEN 7.40   -- Curcuma
             WHEN 7  THEN 6.80   -- Pimenton
             WHEN 8  THEN 8.90   -- Canela en corteza
             WHEN 9  THEN 3.75   -- Hierbas horchata
             WHEN 10 THEN 5.60   -- Laurel
           END;
  END;

  -- materia prima principal que consume cada categoria de producto
  FUNCTION materia_principal (p_categoria NUMBER) RETURN NUMBER IS
  BEGIN
    RETURN CASE p_categoria
             WHEN 1 THEN 1   -- molidas    <- oregano
             WHEN 2 THEN 2   -- enteras    <- comino en grano
             WHEN 3 THEN 10  -- hierbas    <- laurel
             WHEN 4 THEN 3   -- alinos     <- ajo deshidratado
             WHEN 5 THEN 5   -- sales      <- sal marina
             WHEN 6 THEN 9   -- infusiones <- hierbas horchata
             WHEN 7 THEN 8   -- reposteria <- canela
           END;
  END;
BEGIN
  DBMS_RANDOM.SEED(20260723);

  -- =========================================================================
  -- 3.1 DETALLE_COMPRA  (2 a 4 materias primas por factura de compra)
  -- =========================================================================
  v_id := 0;
  FOR c IN (SELECT id_compra FROM compra ORDER BY id_compra) LOOP
    v_lineas := 2 + TRUNC(DBMS_RANDOM.VALUE(0,3));   -- 2..4
    v_total  := 0;
    FOR m IN (SELECT id_materia FROM
                (SELECT id_materia FROM materia_prima ORDER BY DBMS_RANDOM.VALUE)
               WHERE ROWNUM <= v_lineas) LOOP
      v_cant   := ROUND(DBMS_RANDOM.VALUE(150,1200), 2);
      v_precio := ROUND(costo_kg(m.id_materia) * DBMS_RANDOM.VALUE(0.92,1.08), 2);
      v_sub    := ROUND(v_cant * v_precio, 2);
      v_id     := v_id + 1;
      INSERT INTO detalle_compra
        VALUES (v_id, c.id_compra, m.id_materia, v_cant, v_precio, v_sub);
      v_total := v_total + v_sub;
    END LOOP;
    -- la cabecera pasa a ser exactamente la suma de sus lineas
    UPDATE compra SET total = v_total WHERE id_compra = c.id_compra;
    v_filas := v_filas + v_lineas;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('DETALLE_COMPRA generado: '||v_filas||' lineas sobre 300 compras');

  -- =========================================================================
  -- 3.2 DETALLE_VENTA  (1 a 3 productos por factura de venta)
  -- =========================================================================
  v_id := 0; v_filas := 0;
  FOR v IN (SELECT id_venta FROM venta ORDER BY id_venta) LOOP
    v_lineas := 1 + TRUNC(DBMS_RANDOM.VALUE(0,3));   -- 1..3
    v_total  := 0;
    FOR p IN (SELECT id_producto, precio FROM
                (SELECT id_producto, precio FROM producto ORDER BY DBMS_RANDOM.VALUE)
               WHERE ROWNUM <= v_lineas) LOOP
      v_cant := 1 + TRUNC(DBMS_RANDOM.VALUE(0,5));   -- 1..5 unidades
      v_sub  := ROUND(v_cant * p.precio, 2);
      v_id   := v_id + 1;
      INSERT INTO detalle_venta
        VALUES (v_id, v.id_venta, p.id_producto, v_cant, p.precio, v_sub);
      v_total := v_total + v_sub;
    END LOOP;
    UPDATE venta SET total = v_total WHERE id_venta = v.id_venta;
    v_filas := v_filas + v_lineas;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('DETALLE_VENTA generado : '||v_filas||' lineas sobre 2500 ventas');

  -- =========================================================================
  -- 3.3 PRODUCCION + DETALLE_PRODUCCION (400 lotes de planta)
  -- =========================================================================
  v_id := 0; v_filas := 0;
  FOR i IN 1..400 LOOP
    DECLARE
      v_prod  NUMBER;
      v_cat   NUMBER;
      v_emp   NUMBER;
      v_qty   NUMBER;
      v_fecha DATE;
      v_mat   NUMBER;
    BEGIN
      SELECT id_producto, id_categoria INTO v_prod, v_cat FROM
        (SELECT id_producto, id_categoria FROM producto ORDER BY DBMS_RANDOM.VALUE)
       WHERE ROWNUM = 1;
      v_emp   := 1 + TRUNC(DBMS_RANDOM.VALUE(0,12));
      v_qty   := 200 + TRUNC(DBMS_RANDOM.VALUE(0,1801));
      v_fecha := DATE '2026-01-05' + TRUNC(DBMS_RANDOM.VALUE(0,146));

      INSERT INTO produccion VALUES (i, v_fecha, v_emp, v_prod, v_qty);

      -- consumo de la materia prima principal de esa categoria
      v_mat  := materia_principal(v_cat);
      v_id   := v_id + 1;
      INSERT INTO detalle_produccion
        VALUES (v_id, i, v_mat, ROUND(v_qty * DBMS_RANDOM.VALUE(0.05,0.12), 2));
      v_filas := v_filas + 1;

      -- ~50% de los lotes ademas consumen sal marina como coadyuvante
      IF DBMS_RANDOM.VALUE(0,1) > 0.5 AND v_mat <> 5 THEN
        v_id := v_id + 1;
        INSERT INTO detalle_produccion
          VALUES (v_id, i, 5, ROUND(v_qty * DBMS_RANDOM.VALUE(0.01,0.04), 2));
        v_filas := v_filas + 1;
      END IF;
    END;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('PRODUCCION generada    : 400 lotes / '||v_filas||' lineas de consumo');

  COMMIT;
END;
/

-- ---------------------------------------------------------------------------
-- PASO 4: cerrar la FK que quedo pendiente en la importacion del DMP
-- ---------------------------------------------------------------------------
ALTER TABLE producto ADD CONSTRAINT fk_producto_categoria
  FOREIGN KEY (id_categoria) REFERENCES categoria (id_categoria);

-- ---------------------------------------------------------------------------
-- PASO 5: estadisticas frescas para el optimizador
-- ---------------------------------------------------------------------------
BEGIN
  DBMS_STATS.GATHER_SCHEMA_STATS(USER, cascade => TRUE);
END;
/

PROMPT
PROMPT === Reconstruccion completada ===
