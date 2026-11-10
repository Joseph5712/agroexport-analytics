-- AgroExport · 02 · Bitácora de cargas y tablas de calidad

-- Una fila por cada intento de carga de una entrega (paquete de archivos).
IF OBJECT_ID('etl.LoadBatch') IS NULL
CREATE TABLE etl.LoadBatch
(
    LoadBatchID     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LoadBatch PRIMARY KEY,
    PackageName     NVARCHAR(100) NOT NULL,     -- carpeta de la entrega, p. ej. entrega_2026-10-31
    PackageSha256   CHAR(64)      NOT NULL,     -- huella de TODO el paquete (ver agroexport/manifest.py)
    CutDate         DATE          NOT NULL,     -- fecha de corte que declara el manifiesto
    Status          VARCHAR(10)   NOT NULL CONSTRAINT DF_LoadBatch_Status DEFAULT ('Running'),
    StartedAtUtc    DATETIME2(0)  NOT NULL CONSTRAINT DF_LoadBatch_Started DEFAULT (SYSUTCDATETIME()),
    FinishedAtUtc   DATETIME2(0)  NULL,
    RowsRead        INT NULL,                   -- filas leídas de todos los archivos
    RowsRejected    INT NULL,                   -- filas que no pasaron validación
    RowsDuplicated  INT NULL,                   -- duplicados idénticos descartados
    ErrorMessage    NVARCHAR(2000) NULL,
    CONSTRAINT CK_LoadBatch_Status CHECK (Status IN ('Running', 'Succeeded', 'Failed', 'Skipped'))
);

-- Garantía de idempotencia en la propia base: un mismo paquete solo puede
-- terminar en Succeeded una vez, aunque dos procesos lo intenten a la vez.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_LoadBatch_SucceededPackage')
CREATE UNIQUE INDEX UX_LoadBatch_SucceededPackage
    ON etl.LoadBatch (PackageSha256)
    WHERE Status = 'Succeeded';

-- Los archivos que formaron parte de cada intento, con su huella individual.
IF OBJECT_ID('etl.LoadBatchFile') IS NULL
CREATE TABLE etl.LoadBatchFile
(
    LoadBatchID  BIGINT        NOT NULL CONSTRAINT FK_LoadBatchFile_Batch REFERENCES etl.LoadBatch (LoadBatchID),
    FileName     NVARCHAR(100) NOT NULL,
    FileSha256   CHAR(64)      NOT NULL,
    RowsInFile   INT           NOT NULL,
    CONSTRAINT PK_LoadBatchFile PRIMARY KEY (LoadBatchID, FileName)
);

-- Filas que Python rechazó, con el motivo y el contenido original para revisarlas.
IF OBJECT_ID('dq.RejectedRow') IS NULL
CREATE TABLE dq.RejectedRow
(
    RejectedRowID BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_RejectedRow PRIMARY KEY,
    LoadBatchID   BIGINT        NOT NULL CONSTRAINT FK_RejectedRow_Batch REFERENCES etl.LoadBatch (LoadBatchID),
    FileName      NVARCHAR(100) NOT NULL,
    LineNumber    INT           NOT NULL,       -- línea del CSV (la 1 es el encabezado)
    Reason        NVARCHAR(400) NOT NULL,
    RawData       NVARCHAR(MAX) NOT NULL        -- la fila original en JSON
);

-- Conciliación: lo que había en staging contra lo que quedó en el almacén.
IF OBJECT_ID('dq.Reconciliation') IS NULL
CREATE TABLE dq.Reconciliation
(
    LoadBatchID   BIGINT        NOT NULL CONSTRAINT FK_Reconciliation_Batch REFERENCES etl.LoadBatch (LoadBatchID),
    Dataset       VARCHAR(30)   NOT NULL,
    SourceRows    INT           NOT NULL,
    TargetRows    INT           NOT NULL,
    SourceAmount  DECIMAL(19,2) NOT NULL,
    TargetAmount  DECIMAL(19,2) NOT NULL,
    IsMatch       AS CAST(CASE WHEN SourceRows = TargetRows AND SourceAmount = TargetAmount THEN 1 ELSE 0 END AS BIT),
    CONSTRAINT PK_Reconciliation PRIMARY KEY (LoadBatchID, Dataset)
);

-- Alertas de negocio calculadas después de publicar (no bloquean la carga).
IF OBJECT_ID('dq.CheckResult') IS NULL
CREATE TABLE dq.CheckResult
(
    LoadBatchID   BIGINT        NOT NULL CONSTRAINT FK_CheckResult_Batch REFERENCES etl.LoadBatch (LoadBatchID),
    CheckCode     VARCHAR(10)   NOT NULL,
    Description   NVARCHAR(200) NOT NULL,
    Severity      VARCHAR(10)   NOT NULL CONSTRAINT CK_CheckResult_Severity CHECK (Severity IN ('INFO', 'WARN')),
    AffectedRows  INT           NOT NULL,
    CONSTRAINT PK_CheckResult PRIMARY KEY (LoadBatchID, CheckCode)
);
GO
