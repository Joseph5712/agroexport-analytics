-- AgroExport · 01 · Esquemas
-- Un esquema es una "carpeta" dentro de la base. Separamos por responsabilidad:
--   stg  datos de la entrega actual, ya validados por Python (se vacía en cada carga)
--   dw   almacén dimensional: dimensiones y hechos que se conservan
--   etl  bitácora de cargas y archivos recibidos
--   dq   calidad: filas rechazadas, conciliaciones y alertas
--   rpt  vistas de consumo para Power BI (la única capa que ve el reporte)

IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID('dw')  IS NULL EXEC('CREATE SCHEMA dw');
IF SCHEMA_ID('etl') IS NULL EXEC('CREATE SCHEMA etl');
IF SCHEMA_ID('dq')  IS NULL EXEC('CREATE SCHEMA dq');
IF SCHEMA_ID('rpt') IS NULL EXEC('CREATE SCHEMA rpt');
GO
