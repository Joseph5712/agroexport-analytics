-- AgroExport · 07 · Alertas de calidad y de negocio
-- Se ejecutan después de publicar, dentro de la misma transacción.
-- No bloquean la carga: dejan constancia de condiciones que alguien debe revisar.
-- Los errores que SÍ bloquean están en Python (validación) y en la conciliación.

CREATE OR ALTER PROCEDURE dq.usp_RunChecks
    @LoadBatchID BIGINT,
    @CutDate     DATE
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @CutKey INT = CONVERT(INT, CONVERT(CHAR(8), @CutDate, 112));

    INSERT dq.CheckResult (LoadBatchID, CheckCode, Description, Severity, AffectedRows)
    SELECT @LoadBatchID, 'DQ01', N'Líneas de factura con margen negativo', 'WARN',
           (SELECT COUNT(*) FROM dw.FactSalesLine
            WHERE DocType = 'INV' AND IsCancelled = 0 AND NetAmountUsd < CostAmountUsd)
    UNION ALL
    SELECT @LoadBatchID, 'DQ02', N'Líneas de factura sin lote asignado (sin trazabilidad)', 'WARN',
           (SELECT COUNT(*) FROM dw.FactSalesLine
            WHERE DocType = 'INV' AND IsCancelled = 0 AND LotCode IS NULL)
    UNION ALL
    SELECT @LoadBatchID, 'DQ03', N'Embarques pendientes con fecha programada vencida al corte', 'WARN',
           (SELECT COUNT(*) FROM dw.FactShipment
            WHERE Status = 'PENDING' AND ScheduledDateKey < @CutKey)
    UNION ALL
    SELECT @LoadBatchID, 'DQ04', N'Lotes vencidos que aún tienen existencia en el último corte', 'WARN',
           (SELECT COUNT(*) FROM dw.FactLotSnapshot
            WHERE SnapshotDateKey = @CutKey AND ExpiryDate < @CutDate AND QtyKg > 0)
    UNION ALL
    SELECT @LoadBatchID, 'DQ05', N'Documentos con más de 90 días de vencidos en el último corte', 'WARN',
           (SELECT COUNT(*) FROM dw.FactReceivableSnapshot
            WHERE SnapshotDateKey = @CutKey AND DATEDIFF(DAY, DueDate, @CutDate) > 90)
    UNION ALL
    SELECT @LoadBatchID, 'DQ06', N'Notas de crédito cuya factura de referencia no existe', 'WARN',
           (SELECT COUNT(*) FROM dw.FactSalesLine AS cn
            WHERE cn.DocType = 'CN'
              AND NOT EXISTS (SELECT 1 FROM dw.FactSalesLine AS inv
                              WHERE inv.CompanyKey = cn.CompanyKey AND inv.DocType = 'INV'
                                AND inv.DocNumber = cn.RefDocNumber));
END;
GO
