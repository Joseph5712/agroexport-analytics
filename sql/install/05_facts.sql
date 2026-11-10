-- AgroExport · 05 · Hechos
-- Un hecho registra "lo que pasó" y se mide. Lo primero es definir la
-- GRANULARIDAD, es decir, qué representa exactamente una fila:
--
--   FactSalesLine           una línea de factura o nota de crédito
--   FactLotSnapshot         un lote en una fecha de corte (fotografía)
--   FactShipment            un embarque, en su último estado conocido
--   FactReceivableSnapshot  un documento con saldo abierto en una fecha de corte
--
-- Las fotografías (snapshots) son SEMIADITIVAS: se pueden sumar entre lotes
-- o clientes de un mismo corte, pero NO entre cortes. Sumar el inventario de
-- enero y febrero no da "el inventario", da un número sin sentido.
--
-- LoadBatchID indica qué carga escribió la fila por última vez (linaje).

IF OBJECT_ID('dw.FactSalesLine') IS NULL
CREATE TABLE dw.FactSalesLine
(
    SalesLineID    BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_FactSalesLine PRIMARY KEY,
    CompanyKey     INT           NOT NULL CONSTRAINT FK_FactSales_Company  REFERENCES dw.DimCompany (CompanyKey),
    DocType        CHAR(3)       NOT NULL CONSTRAINT CK_FactSales_DocType CHECK (DocType IN ('INV', 'CN')),
    DocNumber      VARCHAR(20)   NOT NULL,
    LineNumber     INT           NOT NULL,
    DateKey        INT           NOT NULL CONSTRAINT FK_FactSales_Date     REFERENCES dw.DimDate (DateKey),
    CustomerKey    INT           NOT NULL CONSTRAINT FK_FactSales_Customer REFERENCES dw.DimCustomer (CustomerKey),
    ProductKey     INT           NOT NULL CONSTRAINT FK_FactSales_Product  REFERENCES dw.DimProduct (ProductKey),
    LotCode        VARCHAR(40)   NULL,
    RefDocNumber   VARCHAR(20)   NULL,
    Currency       CHAR(3)       NOT NULL,
    UsdPerUnit     DECIMAL(18,6) NOT NULL,       -- tipo de cambio aplicado
    -- Con signo: las notas de crédito restan. Así SUM() da directamente ventas netas.
    Quantity       INT           NOT NULL,
    NetAmountUsd   DECIMAL(18,2) NOT NULL,
    CostAmountUsd  DECIMAL(18,2) NOT NULL,
    IsCancelled    BIT           NOT NULL,       -- anulados: se conservan, pero el reporte los excluye
    LoadBatchID    BIGINT        NOT NULL CONSTRAINT FK_FactSales_Batch REFERENCES etl.LoadBatch (LoadBatchID),
    -- Clave de negocio: identifica la línea en el ERP. Evita duplicados entre cargas.
    CONSTRAINT UQ_FactSalesLine_BusinessKey UNIQUE (CompanyKey, DocType, DocNumber, LineNumber)
);

IF OBJECT_ID('dw.FactLotSnapshot') IS NULL
CREATE TABLE dw.FactLotSnapshot
(
    SnapshotDateKey  INT           NOT NULL CONSTRAINT FK_FactLot_Date    REFERENCES dw.DimDate (DateKey),
    CompanyKey       INT           NOT NULL CONSTRAINT FK_FactLot_Company REFERENCES dw.DimCompany (CompanyKey),
    LotCode          VARCHAR(40)   NOT NULL,
    ProductKey       INT           NOT NULL CONSTRAINT FK_FactLot_Product REFERENCES dw.DimProduct (ProductKey),
    WarehouseCode    VARCHAR(20)   NOT NULL,
    ProductionDate   DATE          NOT NULL,
    ExpiryDate       DATE          NOT NULL,
    QtyKg            DECIMAL(18,3) NOT NULL CONSTRAINT CK_FactLot_Qty CHECK (QtyKg >= 0),
    LoadBatchID      BIGINT        NOT NULL CONSTRAINT FK_FactLot_Batch REFERENCES etl.LoadBatch (LoadBatchID),
    CONSTRAINT PK_FactLotSnapshot PRIMARY KEY (SnapshotDateKey, CompanyKey, LotCode)
);

IF OBJECT_ID('dw.FactShipment') IS NULL
CREATE TABLE dw.FactShipment
(
    ShipmentKey         INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_FactShipment PRIMARY KEY,
    CompanyKey          INT          NOT NULL CONSTRAINT FK_FactShip_Company  REFERENCES dw.DimCompany (CompanyKey),
    ShipmentNumber      VARCHAR(20)  NOT NULL,
    InvoiceNumber       VARCHAR(20)  NOT NULL,
    CustomerKey         INT          NOT NULL CONSTRAINT FK_FactShip_Customer REFERENCES dw.DimCustomer (CustomerKey),
    DestinationCountry  NVARCHAR(50) NOT NULL,
    ScheduledDateKey    INT          NOT NULL CONSTRAINT FK_FactShip_Scheduled REFERENCES dw.DimDate (DateKey),
    ActualShipDateKey   INT          NULL     CONSTRAINT FK_FactShip_Actual    REFERENCES dw.DimDate (DateKey),
    Status              VARCHAR(10)  NOT NULL CONSTRAINT CK_FactShip_Status CHECK (Status IN ('PENDING', 'SHIPPED', 'CANCELLED')),
    Containers          INT          NOT NULL,
    LoadBatchID         BIGINT       NOT NULL CONSTRAINT FK_FactShip_Batch REFERENCES etl.LoadBatch (LoadBatchID),
    CONSTRAINT UQ_FactShipment_BusinessKey UNIQUE (CompanyKey, ShipmentNumber),
    -- Regla de negocio protegida por la base: un embarque despachado tiene fecha real.
    CONSTRAINT CK_FactShip_ActualDate CHECK (
        (Status = 'SHIPPED' AND ActualShipDateKey IS NOT NULL)
        OR (Status <> 'SHIPPED' AND ActualShipDateKey IS NULL))
);

IF OBJECT_ID('dw.FactReceivableSnapshot') IS NULL
CREATE TABLE dw.FactReceivableSnapshot
(
    SnapshotDateKey  INT           NOT NULL CONSTRAINT FK_FactAR_Date     REFERENCES dw.DimDate (DateKey),
    CompanyKey       INT           NOT NULL CONSTRAINT FK_FactAR_Company  REFERENCES dw.DimCompany (CompanyKey),
    DocNumber        VARCHAR(20)   NOT NULL,
    CustomerKey      INT           NOT NULL CONSTRAINT FK_FactAR_Customer REFERENCES dw.DimCustomer (CustomerKey),
    DocDate          DATE          NOT NULL,
    DueDate          DATE          NOT NULL,
    OpenAmountUsd    DECIMAL(18,2) NOT NULL CONSTRAINT CK_FactAR_Amount CHECK (OpenAmountUsd > 0),
    LoadBatchID      BIGINT        NOT NULL CONSTRAINT FK_FactAR_Batch REFERENCES etl.LoadBatch (LoadBatchID),
    CONSTRAINT PK_FactReceivableSnapshot PRIMARY KEY (SnapshotDateKey, CompanyKey, DocNumber)
);
GO
