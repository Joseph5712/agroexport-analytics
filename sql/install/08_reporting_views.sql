-- AgroExport · 08 · Vistas de consumo (esquema rpt)
-- Power BI solo lee estas vistas. Ventajas:
--   * Si cambia una tabla interna, se ajusta la vista y el reporte no se rompe.
--   * Las reglas (excluir anulados, días de atraso, tramos de antigüedad)
--     se calculan en un solo lugar y no se repiten en DAX.

CREATE OR ALTER VIEW rpt.DimCompany AS
SELECT CompanyKey, CompanyCode, CompanyName, Country, LocalCurrency
FROM dw.DimCompany;
GO

-- CompanyCode se incluye para aplicar seguridad por sociedad también a los nombres de clientes.
CREATE OR ALTER VIEW rpt.DimCustomer AS
SELECT cu.CustomerKey, c.CompanyCode, cu.CustomerCode, cu.CustomerName,
       cu.Country, cu.PaymentTermsDays
FROM dw.DimCustomer AS cu
JOIN dw.DimCompany  AS c ON c.CompanyKey = cu.CompanyKey;
GO

CREATE OR ALTER VIEW rpt.DimProduct AS
SELECT p.ProductKey, c.CompanyCode, p.ProductCode, p.ProductName, p.Category, p.Subcategory,
       p.SalesUnit, p.KgPerUnit, p.ShelfLifeDays
FROM dw.DimProduct AS p
JOIN dw.DimCompany AS c ON c.CompanyKey = p.CompanyKey;
GO

CREATE OR ALTER VIEW rpt.DimDate AS
SELECT DateKey, [Date], [Year], [Quarter], [Month], MonthName, YearMonth, MonthStart, [Day], IsoWeekday
FROM dw.DimDate;
GO

-- Ventas: excluye anulados. Las notas de crédito ya vienen con signo negativo.
CREATE OR ALTER VIEW rpt.FactSales AS
SELECT f.SalesLineID, f.CompanyKey, f.CustomerKey, f.ProductKey, f.DateKey,
       f.DocType, f.DocNumber, f.LineNumber, f.LotCode, f.Currency,
       f.Quantity,
       CONVERT(DECIMAL(18,3), f.Quantity * p.KgPerUnit) AS QuantityKg,
       f.NetAmountUsd, f.CostAmountUsd,
       f.NetAmountUsd - f.CostAmountUsd AS MarginUsd
FROM dw.FactSalesLine AS f
JOIN dw.DimProduct    AS p ON p.ProductKey = f.ProductKey
WHERE f.IsCancelled = 0;
GO

CREATE OR ALTER VIEW rpt.FactLotSnapshot AS
SELECT f.SnapshotDateKey, d.[Date] AS SnapshotDate, f.CompanyKey, f.ProductKey,
       f.LotCode, f.WarehouseCode, f.ProductionDate, f.ExpiryDate,
       DATEDIFF(DAY, d.[Date], f.ExpiryDate) AS DaysToExpiry,
       CASE WHEN f.ExpiryDate < d.[Date]                    THEN N'1. Vencido'
            WHEN DATEDIFF(DAY, d.[Date], f.ExpiryDate) <= 7  THEN N'2. 0-7 días'
            WHEN DATEDIFF(DAY, d.[Date], f.ExpiryDate) <= 30 THEN N'3. 8-30 días'
            ELSE N'4. Más de 30 días' END AS ExpiryBucket,
       f.QtyKg
FROM dw.FactLotSnapshot AS f
JOIN dw.DimDate AS d ON d.DateKey = f.SnapshotDateKey;
GO

CREATE OR ALTER VIEW rpt.FactShipment AS
SELECT f.ShipmentKey, f.CompanyKey, f.CustomerKey, f.ShipmentNumber, f.InvoiceNumber,
       f.DestinationCountry, f.ScheduledDateKey, f.ActualShipDateKey,
       sd.[Date] AS ScheduledDate, ad.[Date] AS ActualShipDate,
       f.Status, f.Containers,
       CASE WHEN f.Status = 'SHIPPED' THEN 1 ELSE 0 END AS IsShipped,
       CASE WHEN f.Status = 'SHIPPED' AND ad.[Date] <= sd.[Date] THEN 1 ELSE 0 END AS IsOnTime,
       CASE WHEN f.Status = 'SHIPPED' THEN DATEDIFF(DAY, sd.[Date], ad.[Date]) END AS DaysLate
FROM dw.FactShipment AS f
JOIN dw.DimDate      AS sd ON sd.DateKey = f.ScheduledDateKey
LEFT JOIN dw.DimDate AS ad ON ad.DateKey = f.ActualShipDateKey
WHERE f.Status <> 'CANCELLED';
GO

CREATE OR ALTER VIEW rpt.FactReceivable AS
SELECT f.SnapshotDateKey, d.[Date] AS SnapshotDate, f.CompanyKey, f.CustomerKey,
       f.DocNumber, f.DocDate, f.DueDate,
       DATEDIFF(DAY, f.DueDate, d.[Date]) AS DaysPastDue,
       CASE WHEN f.DueDate >= d.[Date]                     THEN N'0. Al día'
            WHEN DATEDIFF(DAY, f.DueDate, d.[Date]) <= 30  THEN N'1. 1-30 días'
            WHEN DATEDIFF(DAY, f.DueDate, d.[Date]) <= 60  THEN N'2. 31-60 días'
            WHEN DATEDIFF(DAY, f.DueDate, d.[Date]) <= 90  THEN N'3. 61-90 días'
            ELSE N'4. Más de 90 días' END AS AgingBucket,
       f.OpenAmountUsd
FROM dw.FactReceivableSnapshot AS f
JOIN dw.DimDate AS d ON d.DateKey = f.SnapshotDateKey;
GO

-- Tabla de seguridad para RLS (ver powerbi/rls.dax).
CREATE OR ALTER VIEW rpt.SecurityAccess AS
SELECT UserPrincipalName, CompanyCode
FROM dw.UserCompanyAccess;
GO

-- Estado de las cargas, para la página de calidad del reporte.
CREATE OR ALTER VIEW rpt.LoadStatus AS
SELECT b.LoadBatchID, b.PackageName, b.CutDate, b.Status, b.StartedAtUtc, b.FinishedAtUtc,
       b.RowsRead, b.RowsRejected, b.RowsDuplicated, b.ErrorMessage
FROM etl.LoadBatch AS b;
GO

CREATE OR ALTER VIEW rpt.QualityAlerts AS
SELECT r.LoadBatchID, b.CutDate, r.CheckCode, r.Description, r.Severity, r.AffectedRows
FROM dq.CheckResult AS r
JOIN etl.LoadBatch  AS b ON b.LoadBatchID = r.LoadBatchID;
GO
