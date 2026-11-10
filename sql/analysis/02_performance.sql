-- AgroExport · Análisis · Rendimiento: medir antes y después de un índice
--
-- Para que la diferencia se note, genera más volumen primero:
--   python -m agroexport instalar --recrear
--   python -m agroexport generar --escala 10
--   python -m agroexport cargar data/entregas/entrega_2026-10-31
--
-- Pasos:
--   1. Ejecuta el bloque 1 (Query Store + consulta sin índice). En la pestaña
--      de Mensajes anota "lecturas lógicas" de FactSalesLine y el tiempo de CPU.
--   2. Ejecuta el bloque 2 (crear el índice) y repite la consulta.
--   3. Registra ambos resultados en docs/rendimiento.md.
-- Activa el plan de ejecución real (en SSMS: Ctrl+M) para ver Scan contra Seek.

-------------------------------------------------------------------------------
-- 0. Query Store guarda el historial de consultas, planes y tiempos en la base.
-------------------------------------------------------------------------------
ALTER DATABASE CURRENT SET QUERY_STORE = ON;
-- QUERY_CAPTURE_MODE = ALL: en modo AUTO se ignoran consultas poco frecuentes como esta demo.
ALTER DATABASE CURRENT SET QUERY_STORE (OPERATION_MODE = READ_WRITE, QUERY_CAPTURE_MODE = ALL);
GO

-------------------------------------------------------------------------------
-- 1. La consulta a optimizar: ventas por categoría y mes para un trimestre.
--    Sin índice, SQL Server recorre toda la tabla (Clustered Index Scan).
-------------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_FactSalesLine_Date_Cover')
    DROP INDEX IX_FactSalesLine_Date_Cover ON dw.FactSalesLine;
GO

SET STATISTICS IO, TIME ON;

SELECT p.Category, d.YearMonth, SUM(f.NetAmountUsd) AS NetSales, SUM(f.CostAmountUsd) AS Cost
FROM dw.FactSalesLine AS f
JOIN dw.DimProduct    AS p ON p.ProductKey = f.ProductKey
JOIN dw.DimDate       AS d ON d.DateKey = f.DateKey
WHERE f.DateKey BETWEEN 20260701 AND 20260930
  AND f.IsCancelled = 0
GROUP BY p.Category, d.YearMonth
OPTION (RECOMPILE);

SET STATISTICS IO, TIME OFF;
GO

-------------------------------------------------------------------------------
-- 2. Índice de cobertura: ordenado por fecha (filtro del WHERE) e incluye las
--    columnas que la consulta necesita, para no volver a la tabla base.
-------------------------------------------------------------------------------
CREATE INDEX IX_FactSalesLine_Date_Cover
    ON dw.FactSalesLine (DateKey)
    INCLUDE (ProductKey, NetAmountUsd, CostAmountUsd, IsCancelled);
GO

SET STATISTICS IO, TIME ON;

SELECT p.Category, d.YearMonth, SUM(f.NetAmountUsd) AS NetSales, SUM(f.CostAmountUsd) AS Cost
FROM dw.FactSalesLine AS f
JOIN dw.DimProduct    AS p ON p.ProductKey = f.ProductKey
JOIN dw.DimDate       AS d ON d.DateKey = f.DateKey
WHERE f.DateKey BETWEEN 20260701 AND 20260930
  AND f.IsCancelled = 0
GROUP BY p.Category, d.YearMonth
OPTION (RECOMPILE);

SET STATISTICS IO, TIME OFF;
GO

-------------------------------------------------------------------------------
-- 3. Lo que Query Store registró de esa consulta (lecturas y duración promedio por plan).
-------------------------------------------------------------------------------
SELECT q.query_id, p.plan_id, rs.count_executions,
       CAST(rs.avg_logical_io_reads AS DECIMAL(12,1)) AS avg_logical_reads,
       CAST(rs.avg_duration / 1000.0 AS DECIMAL(12,2)) AS avg_duration_ms,
       LEFT(qt.query_sql_text, 80) AS query_text
FROM sys.query_store_query_text    AS qt
JOIN sys.query_store_query         AS q  ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_plan          AS p  ON p.query_id = q.query_id
JOIN sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id
WHERE qt.query_sql_text LIKE '%SUM(f.NetAmountUsd) AS NetSales, SUM(f.CostAmountUsd)%'
  AND qt.query_sql_text NOT LIKE '%query_store%'
ORDER BY p.plan_id;
