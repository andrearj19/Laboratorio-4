# -*- coding: utf-8 -*-
"""
============================================================================
03_ETL_ORACLE_A_MONGO.PY
Proyecto ILE - Base de Datos Avanzada - UTPL

METODO DE MIGRACION: ETL orientado a agregados (aggregate-oriented ETL)

    Oracle XE 21c (XEPDB1 / usuario_ile)  --->  MongoDB 8.3 (ile_nosql)

No se hace una copia tabla-a-coleccion. Se aplica la metodologia query-first:
se identifican los patrones de acceso del negocio, se define un AGREGADO por
cada uno (la unidad que siempre se lee junta) y el ETL materializa ese
agregado como un unico documento con sus lineas EMBEBIDAS.

    12 tablas relacionales  --->  9 colecciones documentales

Reglas de modelado aplicadas:
  * EMBEBER  cuando la relacion es 1:pocos y siempre se lee junta
             (detalle_venta dentro de la venta, consumo dentro del lote)
  * DUPLICAR el subconjunto estable del maestro dentro del agregado
             (nombre de producto, categoria, cliente) para eliminar los JOIN
  * REFERENCIAR conservando ademas las colecciones maestras completas,
             que siguen siendo la fuente de verdad para mantenimiento

Importes monetarios: se migran como Decimal128 (no double) para conservar la
aritmetica decimal exacta de Oracle NUMBER(p,s) y evitar errores de redondeo
binario en las agregaciones.

USO:  python 03_etl_oracle_a_mongo.py
============================================================================
"""

import sys
import time
from collections import OrderedDict
from decimal import Decimal

import oracledb
from bson.decimal128 import Decimal128
from pymongo import MongoClient, ASCENDING, DESCENDING

# --------------------------------------------------------------------------
# Configuracion de conexiones
# --------------------------------------------------------------------------
ORACLE_USER = "usuario_ile"
ORACLE_PWD = "Ile_2026"
ORACLE_DSN = "localhost:1521/XEPDB1"

MONGO_URI = "mongodb://localhost:27017"
MONGO_DB = "ile_nosql"

LOTE = 500  # tamano de bloque para insert_many


def dec(valor):
    """Convierte un NUMBER de Oracle a Decimal128 preservando los decimales."""
    if valor is None:
        return None
    return Decimal128(Decimal(str(valor)))


def titulo(texto):
    print()
    print("=" * 74)
    print(texto)
    print("=" * 74)


def paso(texto):
    print("  -> " + texto)


# ==========================================================================
# FASE 1 - EXTRACCION Y CARGA DE LAS COLECCIONES MAESTRAS
#          Son catalogos pequenos y estables: se migran 1:1 como referencia.
# ==========================================================================
def migrar_maestros(cur, db):
    titulo("FASE 1 - COLECCIONES MAESTRAS (migracion 1:1 de catalogos)")
    resumen = {}

    # --- categorias ---
    cur.execute("SELECT id_categoria, nombre, descripcion FROM categoria ORDER BY 1")
    docs = [{"_id": r[0], "nombre": r[1], "descripcion": r[2]} for r in cur]
    db.categorias.drop()
    db.categorias.insert_many(docs)
    resumen["categorias"] = len(docs)
    paso("categorias           : %4d documentos" % len(docs))

    # --- clientes ---
    cur.execute("""SELECT id_cliente, nombres, apellidos, cedula, direccion, telefono
                     FROM cliente ORDER BY 1""")
    docs = [{"_id": r[0],
             "cedula": r[3],
             "nombres": r[1],
             "apellidos": r[2],
             "nombre_completo": "%s %s" % (r[1], r[2]),
             "direccion": r[4],
             "telefono": r[5]} for r in cur]
    db.clientes.drop()
    db.clientes.insert_many(docs)
    resumen["clientes"] = len(docs)
    paso("clientes             : %4d documentos" % len(docs))

    # --- proveedores ---
    cur.execute("""SELECT id_proveedor, nombre_company, ruc, telefono
                     FROM proveedor ORDER BY 1""")
    docs = [{"_id": r[0], "nombre_company": r[1], "ruc": r[2], "telefono": r[3]}
            for r in cur]
    db.proveedores.drop()
    db.proveedores.insert_many(docs)
    resumen["proveedores"] = len(docs)
    paso("proveedores          : %4d documentos" % len(docs))

    # --- empleados ---
    cur.execute("""SELECT id_empleado, nombre, cedula, cargo, fecha_ingreso
                     FROM empleado ORDER BY 1""")
    docs = [{"_id": r[0], "nombre": r[1], "cedula": r[2], "cargo": r[3],
             "fecha_ingreso": r[4]} for r in cur]
    db.empleados.drop()
    db.empleados.insert_many(docs)
    resumen["empleados"] = len(docs)
    paso("empleados            : %4d documentos" % len(docs))

    # --- materias primas ---
    cur.execute("""SELECT id_materia, nombre, unidad_medida, stock
                     FROM materia_prima ORDER BY 1""")
    docs = [{"_id": r[0], "nombre": r[1], "unidad_medida": r[2],
             "stock": dec(r[3])} for r in cur]
    db.materias_primas.drop()
    db.materias_primas.insert_many(docs)
    resumen["materias_primas"] = len(docs)
    paso("materias_primas      : %4d documentos" % len(docs))

    # --- productos: la categoria se DENORMALIZA dentro del producto ---
    cur.execute("""SELECT p.id_producto, p.nombre, p.descripcion, p.precio, p.stock,
                          c.id_categoria, c.nombre
                     FROM producto p JOIN categoria c ON c.id_categoria = p.id_categoria
                    ORDER BY p.id_producto""")
    docs = [{"_id": r[0], "nombre": r[1], "descripcion": r[2],
             "precio": dec(r[3]), "stock": r[4],
             "categoria": {"id": r[5], "nombre": r[6]}} for r in cur]
    db.productos.drop()
    db.productos.insert_many(docs)
    resumen["productos"] = len(docs)
    paso("productos            : %4d documentos (categoria embebida)" % len(docs))

    return resumen


# ==========================================================================
# FASE 2 - AGREGADO "VENTA"
#   Patron de acceso: "dame las facturas de un cliente, con sus lineas".
#   venta + cliente + detalle_venta + producto + categoria  -->  1 documento
# ==========================================================================
def migrar_ventas(cur, db):
    titulo("FASE 2 - AGREGADO VENTA (cabecera + cliente + items embebidos)")
    cur.execute("""
        SELECT v.id_venta, v.fecha,
               c.id_cliente, c.cedula, c.nombres, c.apellidos, c.direccion, c.telefono,
               d.id_detalle_venta, d.cantidad, d.precio_unitario, d.subtotal,
               p.id_producto, p.nombre,
               cat.id_categoria, cat.nombre
          FROM venta v
          JOIN cliente        c   ON c.id_cliente   = v.id_cliente
          JOIN detalle_venta  d   ON d.id_venta     = v.id_venta
          JOIN producto       p   ON p.id_producto  = d.id_producto
          JOIN categoria      cat ON cat.id_categoria = p.id_categoria
         ORDER BY v.id_venta, d.id_detalle_venta
    """)

    db.ventas.drop()
    docs, buffer, actual, total_filas = OrderedDict(), [], None, 0

    for r in cur:
        total_filas += 1
        id_venta = r[0]
        if actual is None or actual["_id"] != id_venta:
            if actual is not None:
                buffer.append(cerrar_venta(actual))
                if len(buffer) >= LOTE:
                    db.ventas.insert_many(buffer)
                    buffer = []
            actual = {
                "_id": id_venta,
                "fecha": r[1],
                "cliente": {"id": r[2], "cedula": r[3],
                            "nombres": r[4], "apellidos": r[5],
                            "nombre_completo": "%s %s" % (r[4], r[5]),
                            "direccion": r[6], "telefono": r[7]},
                "items": [],
            }
        actual["items"].append({
            "producto": {"id": r[12], "nombre": r[13],
                         "categoria": {"id": r[14], "nombre": r[15]}},
            "cantidad": r[9],
            "precio_unitario": dec(r[10]),
            "subtotal": dec(r[11]),
        })

    if actual is not None:
        buffer.append(cerrar_venta(actual))
    if buffer:
        db.ventas.insert_many(buffer)

    n = db.ventas.count_documents({})
    paso("%d filas relacionales colapsadas en %d documentos" % (total_filas, n))
    return n


def cerrar_venta(doc):
    """Calcula los campos derivados del agregado antes de insertarlo."""
    total = sum(Decimal(str(i["subtotal"].to_decimal())) for i in doc["items"])
    doc["total"] = Decimal128(total)
    doc["n_items"] = len(doc["items"])
    doc["unidades_totales"] = sum(i["cantidad"] for i in doc["items"])
    return doc


# ==========================================================================
# FASE 3 - AGREGADO "COMPRA"
#   compra + proveedor + detalle_compra + materia_prima  -->  1 documento
# ==========================================================================
def migrar_compras(cur, db):
    titulo("FASE 3 - AGREGADO COMPRA (cabecera + proveedor + items embebidos)")
    cur.execute("""
        SELECT c.id_compra, c.fecha,
               pr.id_proveedor, pr.nombre_company, pr.ruc, pr.telefono,
               d.id_detalle_compra, d.cantidad, d.precio_unitario, d.subtotal,
               m.id_materia, m.nombre, m.unidad_medida
          FROM compra c
          JOIN proveedor      pr ON pr.id_proveedor = c.id_proveedor
          JOIN detalle_compra d  ON d.id_compra     = c.id_compra
          JOIN materia_prima  m  ON m.id_materia    = d.id_materia
         ORDER BY c.id_compra, d.id_detalle_compra
    """)

    db.compras.drop()
    buffer, actual, total_filas = [], None, 0

    for r in cur:
        total_filas += 1
        id_compra = r[0]
        if actual is None or actual["_id"] != id_compra:
            if actual is not None:
                buffer.append(cerrar_compra(actual))
                if len(buffer) >= LOTE:
                    db.compras.insert_many(buffer)
                    buffer = []
            actual = {
                "_id": id_compra,
                "fecha": r[1],
                "proveedor": {"id": r[2], "nombre_company": r[3],
                              "ruc": r[4], "telefono": r[5]},
                "items": [],
            }
        actual["items"].append({
            "materia": {"id": r[10], "nombre": r[11], "unidad_medida": r[12]},
            "cantidad": dec(r[7]),
            "precio_unitario": dec(r[8]),
            "subtotal": dec(r[9]),
        })

    if actual is not None:
        buffer.append(cerrar_compra(actual))
    if buffer:
        db.compras.insert_many(buffer)

    n = db.compras.count_documents({})
    paso("%d filas relacionales colapsadas en %d documentos" % (total_filas, n))
    return n


def cerrar_compra(doc):
    total = sum(Decimal(str(i["subtotal"].to_decimal())) for i in doc["items"])
    doc["total"] = Decimal128(total)
    doc["n_items"] = len(doc["items"])
    doc["kg_totales"] = Decimal128(
        sum(Decimal(str(i["cantidad"].to_decimal())) for i in doc["items"]))
    return doc


# ==========================================================================
# FASE 4 - AGREGADO "PRODUCCION"
#   produccion + empleado + producto + detalle_produccion + materia_prima
# ==========================================================================
def migrar_produccion(cur, db):
    titulo("FASE 4 - AGREGADO PRODUCCION (lote + empleado + consumo embebido)")
    cur.execute("""
        SELECT pr.id_produccion, pr.fecha, pr.cantidad_producida,
               e.id_empleado, e.nombre, e.cargo, e.cedula,
               p.id_producto, p.nombre,
               cat.id_categoria, cat.nombre,
               d.id_detalle_produccion, d.cantidad_utilizada,
               m.id_materia, m.nombre, m.unidad_medida
          FROM produccion         pr
          JOIN empleado           e   ON e.id_empleado    = pr.id_empleado
          JOIN producto           p   ON p.id_producto    = pr.id_producto
          JOIN categoria          cat ON cat.id_categoria = p.id_categoria
          JOIN detalle_produccion d   ON d.id_produccion  = pr.id_produccion
          JOIN materia_prima      m   ON m.id_materia     = d.id_materia
         ORDER BY pr.id_produccion, d.id_detalle_produccion
    """)

    db.produccion.drop()
    buffer, actual, total_filas = [], None, 0

    for r in cur:
        total_filas += 1
        id_lote = r[0]
        if actual is None or actual["_id"] != id_lote:
            if actual is not None:
                buffer.append(cerrar_lote(actual))
                if len(buffer) >= LOTE:
                    db.produccion.insert_many(buffer)
                    buffer = []
            actual = {
                "_id": id_lote,
                "fecha": r[1],
                "cantidad_producida": r[2],
                "empleado": {"id": r[3], "nombre": r[4], "cargo": r[5], "cedula": r[6]},
                "producto": {"id": r[7], "nombre": r[8],
                             "categoria": {"id": r[9], "nombre": r[10]}},
                "consumo": [],
            }
        actual["consumo"].append({
            "materia": {"id": r[13], "nombre": r[14], "unidad_medida": r[15]},
            "cantidad_utilizada": dec(r[12]),
        })

    if actual is not None:
        buffer.append(cerrar_lote(actual))
    if buffer:
        db.produccion.insert_many(buffer)

    n = db.produccion.count_documents({})
    paso("%d filas relacionales colapsadas en %d documentos" % (total_filas, n))
    return n


def cerrar_lote(doc):
    doc["mp_consumida_total"] = Decimal128(
        sum(Decimal(str(c["cantidad_utilizada"].to_decimal())) for c in doc["consumo"]))
    doc["n_materias"] = len(doc["consumo"])
    return doc


# ==========================================================================
# FASE 5 - INDICES DERIVADOS DE LOS PATRONES DE ACCESO
# ==========================================================================
def crear_indices(db):
    titulo("FASE 5 - INDICES (uno por cada patron de acceso identificado)")

    db.ventas.create_index([("cliente.id", ASCENDING), ("fecha", DESCENDING)],
                           name="ix_ventas_cliente_fecha")
    paso("ventas     {cliente.id:1, fecha:-1}       -> facturas de un cliente")
    db.ventas.create_index([("fecha", DESCENDING)], name="ix_ventas_fecha")
    paso("ventas     {fecha:-1}                     -> ventas por periodo")
    db.ventas.create_index([("items.producto.id", ASCENDING)], name="ix_ventas_producto")
    paso("ventas     {items.producto.id:1}          -> indice multiclave sobre el array")
    db.ventas.create_index([("items.producto.categoria.id", ASCENDING)],
                           name="ix_ventas_categoria")
    paso("ventas     {items.producto.categoria.id:1}-> ranking por categoria")

    db.compras.create_index([("proveedor.id", ASCENDING), ("fecha", DESCENDING)],
                            name="ix_compras_proveedor_fecha")
    paso("compras    {proveedor.id:1, fecha:-1}     -> compras a un proveedor")
    db.compras.create_index([("items.materia.id", ASCENDING)], name="ix_compras_materia")
    paso("compras    {items.materia.id:1}           -> trazabilidad de materia prima")

    db.produccion.create_index([("empleado.id", ASCENDING), ("fecha", DESCENDING)],
                               name="ix_prod_empleado_fecha")
    paso("produccion {empleado.id:1, fecha:-1}      -> lotes por operario")
    db.produccion.create_index([("producto.id", ASCENDING)], name="ix_prod_producto")
    paso("produccion {producto.id:1}                -> lotes de un producto")
    db.produccion.create_index([("consumo.materia.id", ASCENDING)], name="ix_prod_materia")
    paso("produccion {consumo.materia.id:1}         -> consumo por materia prima")

    db.productos.create_index([("categoria.id", ASCENDING)], name="ix_productos_categoria")
    db.productos.create_index([("nombre", ASCENDING)], name="ux_productos_nombre", unique=True)
    db.clientes.create_index([("cedula", ASCENDING)], name="ux_clientes_cedula", unique=True)
    db.proveedores.create_index([("ruc", ASCENDING)], name="ux_proveedores_ruc", unique=True)
    paso("maestros   indices unicos sobre cedula / ruc / nombre de producto")


# ==========================================================================
# FASE 6 - VERIFICACION POST-MIGRACION (Oracle vs MongoDB)
# ==========================================================================
def verificar(cur, db):
    titulo("FASE 6 - VERIFICACION DE LA MIGRACION (Oracle vs MongoDB)")

    def suma_mongo(coleccion, campo):
        r = list(db[coleccion].aggregate([
            {"$group": {"_id": None, "s": {"$sum": "$" + campo}}}]))
        return Decimal(str(r[0]["s"].to_decimal())) if r else Decimal(0)

    def escalar(sql):
        cur.execute(sql)
        return cur.fetchone()[0]

    pruebas = []

    # conteos
    for tabla, coleccion in [("cliente", "clientes"), ("proveedor", "proveedores"),
                             ("empleado", "empleados"), ("materia_prima", "materias_primas"),
                             ("categoria", "categorias"), ("producto", "productos"),
                             ("venta", "ventas"), ("compra", "compras"),
                             ("produccion", "produccion")]:
        o = escalar("SELECT COUNT(*) FROM " + tabla)
        m = db[coleccion].count_documents({})
        pruebas.append(("conteo %s / %s" % (tabla, coleccion), o, m, o == m))

    # lineas embebidas: cada detalle relacional debe existir como item del array
    o = escalar("SELECT COUNT(*) FROM detalle_venta")
    m = list(db.ventas.aggregate([{"$group": {"_id": None, "s": {"$sum": "$n_items"}}}]))[0]["s"]
    pruebas.append(("lineas detalle_venta -> ventas.items", o, m, o == m))

    o = escalar("SELECT COUNT(*) FROM detalle_compra")
    m = list(db.compras.aggregate([{"$group": {"_id": None, "s": {"$sum": "$n_items"}}}]))[0]["s"]
    pruebas.append(("lineas detalle_compra -> compras.items", o, m, o == m))

    o = escalar("SELECT COUNT(*) FROM detalle_produccion")
    m = list(db.produccion.aggregate([{"$group": {"_id": None, "s": {"$sum": "$n_materias"}}}]))[0]["s"]
    pruebas.append(("lineas detalle_produccion -> consumo", o, m, o == m))

    # sumas monetarias al centavo
    o = Decimal(str(escalar("SELECT SUM(total) FROM venta")))
    m = suma_mongo("ventas", "total")
    pruebas.append(("importe total de ventas", o, m, o == m))

    o = Decimal(str(escalar("SELECT SUM(total) FROM compra")))
    m = suma_mongo("compras", "total")
    pruebas.append(("importe total de compras", o, m, o == m))

    o = escalar("SELECT SUM(cantidad_producida) FROM produccion")
    m = list(db.produccion.aggregate(
        [{"$group": {"_id": None, "s": {"$sum": "$cantidad_producida"}}}]))[0]["s"]
    pruebas.append(("unidades producidas", o, m, o == m))

    print()
    print("  %-42s %14s %14s  %s" % ("PRUEBA", "ORACLE", "MONGODB", "RESULTADO"))
    print("  " + "-" * 88)
    fallos = 0
    for nombre, o, m, ok in pruebas:
        if not ok:
            fallos += 1
        print("  %-42s %14s %14s  %s" % (nombre, o, m, "OK" if ok else "DIFERENCIA"))
    print("  " + "-" * 88)
    print("  %d/%d pruebas superadas" % (len(pruebas) - fallos, len(pruebas)))
    return fallos


# ==========================================================================
def main():
    t0 = time.time()
    titulo("ETL ORACLE -> MONGODB   |   PROYECTO ILE   |   UTPL")
    print("  Origen  : Oracle XE 21c  %s  (esquema %s)" % (ORACLE_DSN, ORACLE_USER))
    print("  Destino : MongoDB 8.3    %s  (base %s)" % (MONGO_URI, MONGO_DB))

    con = oracledb.connect(user=ORACLE_USER, password=ORACLE_PWD, dsn=ORACLE_DSN)
    cur = con.cursor()
    cur.arraysize = 1000
    cliente_mongo = MongoClient(MONGO_URI)
    db = cliente_mongo[MONGO_DB]

    migrar_maestros(cur, db)
    migrar_ventas(cur, db)
    migrar_compras(cur, db)
    migrar_produccion(cur, db)
    crear_indices(db)
    fallos = verificar(cur, db)

    titulo("RESUMEN")
    total = 0
    for c in sorted(db.list_collection_names()):
        n = db[c].count_documents({})
        total += n
        print("  %-18s %7d documentos" % (c, n))
    print("  %-18s %7d documentos" % ("TOTAL", total))
    print()
    print("  Tiempo total: %.1f s" % (time.time() - t0))
    print("  Estado      : %s" % ("MIGRACION CORRECTA" if fallos == 0
                                  else "%d DIFERENCIAS DETECTADAS" % fallos))

    cur.close()
    con.close()
    cliente_mongo.close()
    return 0 if fallos == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
