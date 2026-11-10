-- AgroExport · Análisis · Preguntas de gerencia
-- Ejecuta cada consulta por separado (selecciónala y Ctrl+Shift+E en VS Code).
-- Todas leen las vistas rpt, igual que Power BI: si un número no coincide con
-- el reporte, el problema está en DAX, no en los datos.

-------------------------------------------------------------------------------
-- 1. Ventas y margen por sociedad y mes, contra el mismo mes del año anterior.
--    Técnica: CTE + LEFT JOIN al mismo mes de hace un año (no LAG(…, 12),
--    que fallaría si algún mes no tuviera ventas).
-------------------------------------------------------------------------------
WITH Monthly AS
(
    SELECT c.CompanyCode, d.MonthStart,
           SUM(f.NetAmountUsd) AS NetSales,
           SUM(f.MarginUsd)    AS Margin
    FROM rpt.FactSales  AS f
    JOIN rpt.DimCompany AS c ON c.CompanyKey = f.CompanyKey
    JOIN rpt.DimDate    AS d ON d.DateKey = f.DateKey
    GROUP BY c.CompanyCode, d.MonthStart
)
SELECT cur.CompanyCode,
       cur.MonthStart,
       cur.NetSales,
       CAST(cur.Margin * 100.0 / NULLIF(cur.NetSales, 0) AS DECIMAL(5,1)) AS MarginPct,
       prev.NetSales AS NetSalesLastYear,
       CAST((cur.NetSales - prev.NetSales) * 100.0 / NULLIF(prev.NetSales, 0) AS DECIMAL(6,1)) AS YoYPct,
       -- Variación contra el mes anterior: aquí sí sirve LAG.
       cur.NetSales - LAG(cur.NetSales) OVER (PARTITION BY cur.CompanyCode ORDER BY cur.MonthStart) AS MoMChange
FROM Monthly AS cur
LEFT JOIN Monthly AS prev
       ON prev.CompanyCode = cur.CompanyCode
      AND prev.MonthStart  = DATEADD(YEAR, -1, cur.MonthStart)
ORDER BY cur.CompanyCode, cur.MonthStart;

-------------------------------------------------------------------------------
-- 2. Top 5 productos por ventas netas en los últimos 90 días, por sociedad.
--    DENSE_RANK conserva los empates (dos productos con igual venta comparten puesto).
-------------------------------------------------------------------------------
DECLARE @LastSale DATE = (SELECT MAX(d.[Date]) FROM rpt.FactSales f JOIN rpt.DimDate d ON d.DateKey = f.DateKey);

WITH ProductSales AS
(
    SELECT p.CompanyCode, p.ProductName, p.Category,
           SUM(f.NetAmountUsd) AS NetSales,
           SUM(f.QuantityKg)   AS Kg
    FROM rpt.FactSales  AS f
    JOIN rpt.DimProduct AS p ON p.ProductKey = f.ProductKey
    JOIN rpt.DimDate    AS d ON d.DateKey = f.DateKey
    WHERE d.[Date] > DATEADD(DAY, -90, @LastSale)
    GROUP BY p.CompanyCode, p.ProductName, p.Category
), Ranked AS
(
    SELECT *, DENSE_RANK() OVER (PARTITION BY CompanyCode ORDER BY NetSales DESC) AS SalesRank,
           CAST(NetSales * 100.0 / SUM(NetSales) OVER (PARTITION BY CompanyCode) AS DECIMAL(5,1)) AS SharePct
    FROM ProductSales
)
SELECT CompanyCode, SalesRank, ProductName, Category, NetSales, SharePct, Kg
FROM Ranked
WHERE SalesRank <= 5
ORDER BY CompanyCode, SalesRank;

-------------------------------------------------------------------------------
-- 3. Planta: lotes que vencen en los próximos 30 días, al último corte.
--    Una fotografía se consulta en UNA fecha; nunca se suma entre cortes.
-------------------------------------------------------------------------------
DECLARE @LastLotCut INT = (SELECT MAX(SnapshotDateKey) FROM rpt.FactLotSnapshot);

SELECT c.CompanyCode, l.WarehouseCode, p.ProductName, l.LotCode,
       l.ExpiryDate, l.DaysToExpiry, l.QtyKg
FROM rpt.FactLotSnapshot AS l
JOIN rpt.DimCompany      AS c ON c.CompanyKey = l.CompanyKey
JOIN rpt.DimProduct      AS p ON p.ProductKey = l.ProductKey
WHERE l.SnapshotDateKey = @LastLotCut
  AND l.DaysToExpiry BETWEEN 0 AND 30
ORDER BY l.DaysToExpiry, l.QtyKg DESC;

-------------------------------------------------------------------------------
-- 4. Cobros: antigüedad de la cartera por cliente al último corte.
--    Agregación condicional (SUM + CASE) para poner los tramos en columnas.
-------------------------------------------------------------------------------
DECLARE @LastArCut INT = (SELECT MAX(SnapshotDateKey) FROM rpt.FactReceivable);

SELECT c.CompanyCode, cu.CustomerName,
       SUM(r.OpenAmountUsd) AS OpenTotal,
       SUM(CASE WHEN r.DaysPastDue <= 0              THEN r.OpenAmountUsd ELSE 0 END) AS Current_,
       SUM(CASE WHEN r.DaysPastDue BETWEEN 1  AND 30 THEN r.OpenAmountUsd ELSE 0 END) AS Days1_30,
       SUM(CASE WHEN r.DaysPastDue BETWEEN 31 AND 60 THEN r.OpenAmountUsd ELSE 0 END) AS Days31_60,
       SUM(CASE WHEN r.DaysPastDue BETWEEN 61 AND 90 THEN r.OpenAmountUsd ELSE 0 END) AS Days61_90,
       SUM(CASE WHEN r.DaysPastDue > 90              THEN r.OpenAmountUsd ELSE 0 END) AS Over90,
       MAX(r.DaysPastDue) AS OldestDaysPastDue
FROM rpt.FactReceivable AS r
JOIN rpt.DimCompany     AS c  ON c.CompanyKey  = r.CompanyKey
JOIN rpt.DimCustomer    AS cu ON cu.CustomerKey = r.CustomerKey
WHERE r.SnapshotDateKey = @LastArCut
GROUP BY c.CompanyCode, cu.CustomerName
ORDER BY Over90 DESC, OpenTotal DESC;

-------------------------------------------------------------------------------
-- 5. Logística: puntualidad de embarques por mes y pendientes atrasados.
--    Puntualidad = despachados a tiempo / despachados. No es OTIF: para OTIF
--    faltan la cantidad comprometida y la fecha de entrega en destino.
-------------------------------------------------------------------------------
SELECT c.CompanyCode, d.YearMonth,
       SUM(s.IsShipped) AS Shipped,
       SUM(s.IsOnTime)  AS OnTime,
       CAST(SUM(s.IsOnTime) * 100.0 / NULLIF(SUM(s.IsShipped), 0) AS DECIMAL(5,1)) AS OnTimePct,
       AVG(CASE WHEN s.DaysLate > 0 THEN s.DaysLate * 1.0 END) AS AvgDaysLateWhenLate
FROM rpt.FactShipment AS s
JOIN rpt.DimCompany   AS c ON c.CompanyKey = s.CompanyKey
JOIN rpt.DimDate      AS d ON d.DateKey = s.ScheduledDateKey
GROUP BY c.CompanyCode, d.YearMonth
ORDER BY c.CompanyCode, d.YearMonth;

DECLARE @Cut DATE = (SELECT MAX(CutDate) FROM etl.LoadBatch WHERE Status = 'Succeeded');

SELECT c.CompanyCode, s.ShipmentNumber, s.InvoiceNumber, cu.CustomerName, s.DestinationCountry,
       s.ScheduledDate, DATEDIFF(DAY, s.ScheduledDate, @Cut) AS DaysOverdue
FROM rpt.FactShipment AS s
JOIN rpt.DimCompany   AS c  ON c.CompanyKey  = s.CompanyKey
JOIN rpt.DimCustomer  AS cu ON cu.CustomerKey = s.CustomerKey
WHERE s.Status = 'PENDING' AND s.ScheduledDate < @Cut
ORDER BY DaysOverdue DESC;

-------------------------------------------------------------------------------
-- 6. Ventas acumuladas del año (running total) por sociedad.
--    SUM() OVER con ROWS UNBOUNDED PRECEDING: suma desde enero hasta cada mes.
-------------------------------------------------------------------------------
WITH Monthly AS
(
    SELECT c.CompanyCode, d.[Year], d.[Month], SUM(f.NetAmountUsd) AS NetSales
    FROM rpt.FactSales  AS f
    JOIN rpt.DimCompany AS c ON c.CompanyKey = f.CompanyKey
    JOIN rpt.DimDate    AS d ON d.DateKey = f.DateKey
    GROUP BY c.CompanyCode, d.[Year], d.[Month]
)
SELECT CompanyCode, [Year], [Month], NetSales,
       SUM(NetSales) OVER (PARTITION BY CompanyCode, [Year] ORDER BY [Month]
                           ROWS UNBOUNDED PRECEDING) AS YearToDate
FROM Monthly
ORDER BY CompanyCode, [Year], [Month];

-------------------------------------------------------------------------------
-- 7. Calidad comercial: peso de las notas de crédito sobre la venta bruta por cliente.
-------------------------------------------------------------------------------
SELECT c.CompanyCode, cu.CustomerName,
       SUM(CASE WHEN f.DocType = 'INV' THEN f.NetAmountUsd ELSE 0 END)  AS GrossSales,
       -SUM(CASE WHEN f.DocType = 'CN' THEN f.NetAmountUsd ELSE 0 END)  AS Credits,
       CAST(-SUM(CASE WHEN f.DocType = 'CN' THEN f.NetAmountUsd ELSE 0 END) * 100.0
            / NULLIF(SUM(CASE WHEN f.DocType = 'INV' THEN f.NetAmountUsd ELSE 0 END), 0) AS DECIMAL(5,2)) AS CreditPct
FROM rpt.FactSales   AS f
JOIN rpt.DimCompany  AS c  ON c.CompanyKey  = f.CompanyKey
JOIN rpt.DimCustomer AS cu ON cu.CustomerKey = f.CustomerKey
GROUP BY c.CompanyCode, cu.CustomerName
ORDER BY CreditPct DESC;
