-- AgroExport · 06 · Publicación de staging al almacén
--
-- Python abre la transacción, llena staging y llama a este procedimiento.
-- Si cualquier paso falla (o la conciliación no cuadra), el error sube a
-- Python, que hace ROLLBACK: el almacén queda exactamente como estaba.
--
-- Estrategia por tabla:
--   Dimensiones y FactShipment   UPSERT por clave de negocio (UPDATE + INSERT)
--   FactSalesLine                UPSERT: una corrección o anulación posterior
--                                llega con la misma clave y reemplaza la fila
--   Fotografías (lotes, cartera) se REEMPLAZA completo cada corte recibido
--
-- Se usa UPDATE + INSERT en lugar de MERGE: es más fácil de leer y evita
-- problemas conocidos de MERGE con concurrencia y disparadores.

CREATE OR ALTER PROCEDURE etl.usp_PublishBatch
    @LoadBatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;   -- ante cualquier error, la transacción queda marcada para revertir

    IF @@TRANCOUNT = 0
        THROW 50001, N'etl.usp_PublishBatch debe ejecutarse dentro de una transacción abierta.', 1;

    ---------------------------------------------------------------------------
    -- 1. Dimensiones
    ---------------------------------------------------------------------------
    UPDATE d
    SET    CompanyName = s.CompanyName, Country = s.Country, LocalCurrency = s.LocalCurrency
    FROM   dw.DimCompany AS d
    JOIN   stg.Company   AS s ON s.CompanyCode = d.CompanyCode;

    INSERT dw.DimCompany (CompanyCode, CompanyName, Country, LocalCurrency)
    SELECT s.CompanyCode, s.CompanyName, s.Country, s.LocalCurrency
    FROM   stg.Company AS s
    WHERE  NOT EXISTS (SELECT 1 FROM dw.DimCompany AS d WHERE d.CompanyCode = s.CompanyCode);

    UPDATE d
    SET    CustomerName = s.CustomerName, Country = s.Country, PaymentTermsDays = s.PaymentTermsDays
    FROM   dw.DimCustomer AS d
    JOIN   dw.DimCompany  AS c ON c.CompanyKey = d.CompanyKey
    JOIN   stg.Customer   AS s ON s.CompanyCode = c.CompanyCode AND s.CustomerCode = d.CustomerCode;

    INSERT dw.DimCustomer (CompanyKey, CustomerCode, CustomerName, Country, PaymentTermsDays)
    SELECT c.CompanyKey, s.CustomerCode, s.CustomerName, s.Country, s.PaymentTermsDays
    FROM   stg.Customer  AS s
    JOIN   dw.DimCompany AS c ON c.CompanyCode = s.CompanyCode
    WHERE  NOT EXISTS (SELECT 1 FROM dw.DimCustomer AS d
                       WHERE d.CompanyKey = c.CompanyKey AND d.CustomerCode = s.CustomerCode);

    UPDATE d
    SET    ProductName = s.ProductName, Category = s.Category, Subcategory = s.Subcategory,
           SalesUnit = s.SalesUnit, KgPerUnit = s.KgPerUnit, ShelfLifeDays = s.ShelfLifeDays
    FROM   dw.DimProduct AS d
    JOIN   dw.DimCompany AS c ON c.CompanyKey = d.CompanyKey
    JOIN   stg.Product   AS s ON s.CompanyCode = c.CompanyCode AND s.ProductCode = d.ProductCode;

    INSERT dw.DimProduct (CompanyKey, ProductCode, ProductName, Category, Subcategory, SalesUnit, KgPerUnit, ShelfLifeDays)
    SELECT c.CompanyKey, s.ProductCode, s.ProductName, s.Category, s.Subcategory, s.SalesUnit, s.KgPerUnit, s.ShelfLifeDays
    FROM   stg.Product   AS s
    JOIN   dw.DimCompany AS c ON c.CompanyCode = s.CompanyCode
    WHERE  NOT EXISTS (SELECT 1 FROM dw.DimProduct AS d
                       WHERE d.CompanyKey = c.CompanyKey AND d.ProductCode = s.ProductCode);

    UPDATE f SET UsdPerUnit = s.UsdPerUnit
    FROM   dw.FxRate AS f
    JOIN   stg.FxRate AS s ON s.RateDate = f.RateDate AND s.Currency = f.Currency;

    INSERT dw.FxRate (RateDate, Currency, UsdPerUnit)
    SELECT s.RateDate, s.Currency, s.UsdPerUnit
    FROM   stg.FxRate AS s
    WHERE  NOT EXISTS (SELECT 1 FROM dw.FxRate AS f WHERE f.RateDate = s.RateDate AND f.Currency = s.Currency);

    ---------------------------------------------------------------------------
    -- 2. Líneas de venta: traducir códigos a claves y calcular importes en USD
    ---------------------------------------------------------------------------
    SELECT
        c.CompanyKey, s.DocType, s.DocNumber, s.LineNumber,
        CONVERT(INT, CONVERT(CHAR(8), s.DocDate, 112))           AS DateKey,
        cu.CustomerKey, p.ProductKey, s.LotCode, s.RefDocNumber, s.Currency,
        fx.UsdPerUnit,
        sg.Sign * s.Quantity                                  AS Quantity,
        -- Redondeo a centavos POR LÍNEA, y después el signo.
        sg.Sign * ROUND(s.Quantity * s.UnitPrice * fx.UsdPerUnit, 2) AS NetAmountUsd,
        sg.Sign * s.LineCostUsd                               AS CostAmountUsd,
        CASE s.DocStatus WHEN 'CANCELLED' THEN 1 ELSE 0 END   AS IsCancelled
    INTO #Sales
    FROM stg.SalesLine   AS s
    JOIN dw.DimCompany   AS c  ON c.CompanyCode = s.CompanyCode
    JOIN dw.DimCustomer  AS cu ON cu.CompanyKey = c.CompanyKey AND cu.CustomerCode = s.CustomerCode
    JOIN dw.DimProduct   AS p  ON p.CompanyKey  = c.CompanyKey AND p.ProductCode  = s.ProductCode
    CROSS APPLY (SELECT CASE s.DocType WHEN 'CN' THEN -1 ELSE 1 END AS Sign) AS sg
    -- USD no tiene fila de tipo de cambio: su factor es 1.
    CROSS APPLY (SELECT CASE WHEN s.Currency = 'USD' THEN CONVERT(DECIMAL(18,6), 1)
                             ELSE (SELECT r.UsdPerUnit FROM dw.FxRate AS r
                                   WHERE r.RateDate = s.DocDate AND r.Currency = s.Currency) END AS UsdPerUnit) AS fx;

    UPDATE f
    SET    DateKey = s.DateKey, CustomerKey = s.CustomerKey, ProductKey = s.ProductKey,
           LotCode = s.LotCode, RefDocNumber = s.RefDocNumber, Currency = s.Currency,
           UsdPerUnit = s.UsdPerUnit, Quantity = s.Quantity, NetAmountUsd = s.NetAmountUsd,
           CostAmountUsd = s.CostAmountUsd, IsCancelled = s.IsCancelled, LoadBatchID = @LoadBatchID
    FROM   dw.FactSalesLine AS f
    JOIN   #Sales AS s
           ON  s.CompanyKey = f.CompanyKey AND s.DocType = f.DocType
           AND s.DocNumber  = f.DocNumber  AND s.LineNumber = f.LineNumber;

    INSERT dw.FactSalesLine
        (CompanyKey, DocType, DocNumber, LineNumber, DateKey, CustomerKey, ProductKey, LotCode, RefDocNumber,
         Currency, UsdPerUnit, Quantity, NetAmountUsd, CostAmountUsd, IsCancelled, LoadBatchID)
    SELECT s.CompanyKey, s.DocType, s.DocNumber, s.LineNumber, s.DateKey, s.CustomerKey, s.ProductKey, s.LotCode,
           s.RefDocNumber, s.Currency, s.UsdPerUnit, s.Quantity, s.NetAmountUsd, s.CostAmountUsd, s.IsCancelled, @LoadBatchID
    FROM   #Sales AS s
    WHERE  NOT EXISTS (SELECT 1 FROM dw.FactSalesLine AS f
                       WHERE f.CompanyKey = s.CompanyKey AND f.DocType = s.DocType
                         AND f.DocNumber  = s.DocNumber  AND f.LineNumber = s.LineNumber);

    ---------------------------------------------------------------------------
    -- 3. Embarques: el último estado conocido reemplaza al anterior
    ---------------------------------------------------------------------------
    SELECT c.CompanyKey, s.ShipmentNumber, s.InvoiceNumber, cu.CustomerKey, s.DestinationCountry,
           CONVERT(INT, CONVERT(CHAR(8), s.ScheduledDate, 112)) AS ScheduledDateKey,
           CONVERT(INT, CONVERT(CHAR(8), s.ActualShipDate, 112)) AS ActualShipDateKey,
           s.Status, s.Containers
    INTO   #Shipments
    FROM   stg.Shipment    AS s
    JOIN   dw.DimCompany   AS c  ON c.CompanyCode = s.CompanyCode
    JOIN   dw.DimCustomer  AS cu ON cu.CompanyKey = c.CompanyKey AND cu.CustomerCode = s.CustomerCode;

    UPDATE f
    SET    InvoiceNumber = s.InvoiceNumber, CustomerKey = s.CustomerKey, DestinationCountry = s.DestinationCountry,
           ScheduledDateKey = s.ScheduledDateKey, ActualShipDateKey = s.ActualShipDateKey,
           Status = s.Status, Containers = s.Containers, LoadBatchID = @LoadBatchID
    FROM   dw.FactShipment AS f
    JOIN   #Shipments AS s ON s.CompanyKey = f.CompanyKey AND s.ShipmentNumber = f.ShipmentNumber;

    INSERT dw.FactShipment
        (CompanyKey, ShipmentNumber, InvoiceNumber, CustomerKey, DestinationCountry,
         ScheduledDateKey, ActualShipDateKey, Status, Containers, LoadBatchID)
    SELECT s.CompanyKey, s.ShipmentNumber, s.InvoiceNumber, s.CustomerKey, s.DestinationCountry,
           s.ScheduledDateKey, s.ActualShipDateKey, s.Status, s.Containers, @LoadBatchID
    FROM   #Shipments AS s
    WHERE  NOT EXISTS (SELECT 1 FROM dw.FactShipment AS f
                       WHERE f.CompanyKey = s.CompanyKey AND f.ShipmentNumber = s.ShipmentNumber);

    ---------------------------------------------------------------------------
    -- 4. Fotografías: si llega un corte, reemplaza por completo ese corte.
    --    Así una corrección del mismo corte no deja filas viejas mezcladas.
    ---------------------------------------------------------------------------
    DELETE f
    FROM   dw.FactLotSnapshot AS f
    WHERE  EXISTS (SELECT 1 FROM stg.LotSnapshot AS s
                   JOIN dw.DimCompany AS c ON c.CompanyCode = s.CompanyCode
                   WHERE c.CompanyKey = f.CompanyKey
                     AND CONVERT(INT, CONVERT(CHAR(8), s.SnapshotDate, 112)) = f.SnapshotDateKey);

    INSERT dw.FactLotSnapshot
        (SnapshotDateKey, CompanyKey, LotCode, ProductKey, WarehouseCode, ProductionDate, ExpiryDate, QtyKg, LoadBatchID)
    SELECT CONVERT(INT, CONVERT(CHAR(8), s.SnapshotDate, 112)), c.CompanyKey, s.LotCode, p.ProductKey,
           s.WarehouseCode, s.ProductionDate, s.ExpiryDate, s.QtyKg, @LoadBatchID
    FROM   stg.LotSnapshot AS s
    JOIN   dw.DimCompany   AS c ON c.CompanyCode = s.CompanyCode
    JOIN   dw.DimProduct   AS p ON p.CompanyKey = c.CompanyKey AND p.ProductCode = s.ProductCode;

    DELETE f
    FROM   dw.FactReceivableSnapshot AS f
    WHERE  EXISTS (SELECT 1 FROM stg.Receivable AS s
                   JOIN dw.DimCompany AS c ON c.CompanyCode = s.CompanyCode
                   WHERE c.CompanyKey = f.CompanyKey
                     AND CONVERT(INT, CONVERT(CHAR(8), s.SnapshotDate, 112)) = f.SnapshotDateKey);

    INSERT dw.FactReceivableSnapshot
        (SnapshotDateKey, CompanyKey, DocNumber, CustomerKey, DocDate, DueDate, OpenAmountUsd, LoadBatchID)
    SELECT CONVERT(INT, CONVERT(CHAR(8), s.SnapshotDate, 112)), c.CompanyKey, s.DocNumber, cu.CustomerKey,
           s.DocDate, s.DueDate, s.OpenAmountUsd, @LoadBatchID
    FROM   stg.Receivable  AS s
    JOIN   dw.DimCompany   AS c  ON c.CompanyCode = s.CompanyCode
    JOIN   dw.DimCustomer  AS cu ON cu.CompanyKey = c.CompanyKey AND cu.CustomerCode = s.CustomerCode;

    ---------------------------------------------------------------------------
    -- 5. Conciliación: contar y sumar por DOS caminos distintos.
    --    Origen: directo desde staging. Destino: filas que esta carga escribió.
    --    Si un JOIN perdió filas o las multiplicó, los números no cuadran.
    ---------------------------------------------------------------------------
    INSERT dq.Reconciliation (LoadBatchID, Dataset, SourceRows, TargetRows, SourceAmount, TargetAmount)
    SELECT @LoadBatchID, 'SalesLine',
           (SELECT COUNT(*) FROM stg.SalesLine),
           (SELECT COUNT(*) FROM dw.FactSalesLine WHERE LoadBatchID = @LoadBatchID),
           (SELECT ISNULL(SUM(CASE s.DocType WHEN 'CN' THEN -1 ELSE 1 END
                              * ROUND(s.Quantity * s.UnitPrice
                                      * CASE WHEN s.Currency = 'USD' THEN 1 ELSE r.UsdPerUnit END, 2)), 0)
            FROM stg.SalesLine AS s
            LEFT JOIN stg.FxRate AS r ON r.RateDate = s.DocDate AND r.Currency = s.Currency),
           (SELECT ISNULL(SUM(NetAmountUsd), 0) FROM dw.FactSalesLine WHERE LoadBatchID = @LoadBatchID)
    UNION ALL
    SELECT @LoadBatchID, 'Shipment',
           (SELECT COUNT(*) FROM stg.Shipment),
           (SELECT COUNT(*) FROM dw.FactShipment WHERE LoadBatchID = @LoadBatchID),
           (SELECT ISNULL(SUM(Containers), 0) FROM stg.Shipment),
           (SELECT ISNULL(SUM(Containers), 0) FROM dw.FactShipment WHERE LoadBatchID = @LoadBatchID)
    UNION ALL
    SELECT @LoadBatchID, 'LotSnapshot',
           (SELECT COUNT(*) FROM stg.LotSnapshot),
           (SELECT COUNT(*) FROM dw.FactLotSnapshot WHERE LoadBatchID = @LoadBatchID),
           (SELECT ISNULL(SUM(QtyKg), 0) FROM stg.LotSnapshot),
           (SELECT ISNULL(SUM(QtyKg), 0) FROM dw.FactLotSnapshot WHERE LoadBatchID = @LoadBatchID)
    UNION ALL
    SELECT @LoadBatchID, 'Receivable',
           (SELECT COUNT(*) FROM stg.Receivable),
           (SELECT COUNT(*) FROM dw.FactReceivableSnapshot WHERE LoadBatchID = @LoadBatchID),
           (SELECT ISNULL(SUM(OpenAmountUsd), 0) FROM stg.Receivable),
           (SELECT ISNULL(SUM(OpenAmountUsd), 0) FROM dw.FactReceivableSnapshot WHERE LoadBatchID = @LoadBatchID);

    IF EXISTS (SELECT 1 FROM dq.Reconciliation WHERE LoadBatchID = @LoadBatchID AND IsMatch = 0)
    BEGIN
        DECLARE @Detail NVARCHAR(1000) =
            (SELECT STRING_AGG(CONCAT(Dataset, ': filas ', SourceRows, '/', TargetRows,
                                      ', importe ', SourceAmount, '/', TargetAmount), '; ')
             FROM dq.Reconciliation WHERE LoadBatchID = @LoadBatchID AND IsMatch = 0);
        DECLARE @Message NVARCHAR(2048) = CONCAT(N'La conciliación no cuadra (origen/destino). ', @Detail);
        THROW 50002, @Message, 1;
    END;
END;
GO
