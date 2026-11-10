-- AgroExport · 03 · Staging
-- A diferencia de un staging "todo texto", aquí Python ya validó y convirtió
-- los tipos. Staging guarda solo la entrega actual: se vacía al inicio de cada
-- carga, dentro de la misma transacción que publica al almacén.
-- Las columnas siguen a los CSV (ver agroexport/schemas.py).

IF OBJECT_ID('stg.Company') IS NULL
CREATE TABLE stg.Company
(
    CompanyCode    VARCHAR(10)   NOT NULL PRIMARY KEY,
    CompanyName    NVARCHAR(100) NOT NULL,
    Country        NVARCHAR(50)  NOT NULL,
    LocalCurrency  CHAR(3)       NOT NULL
);

IF OBJECT_ID('stg.Customer') IS NULL
CREATE TABLE stg.Customer
(
    CompanyCode       VARCHAR(10)   NOT NULL,
    CustomerCode      VARCHAR(20)   NOT NULL,
    CustomerName      NVARCHAR(150) NOT NULL,
    Country           NVARCHAR(50)  NOT NULL,
    PaymentTermsDays  INT           NOT NULL,
    PRIMARY KEY (CompanyCode, CustomerCode)
);

IF OBJECT_ID('stg.Product') IS NULL
CREATE TABLE stg.Product
(
    CompanyCode    VARCHAR(10)   NOT NULL,
    ProductCode    VARCHAR(20)   NOT NULL,
    ProductName    NVARCHAR(150) NOT NULL,
    Category       NVARCHAR(50)  NOT NULL,
    Subcategory    NVARCHAR(50)  NOT NULL,
    SalesUnit      NVARCHAR(20)  NOT NULL,
    KgPerUnit      DECIMAL(9,3)  NOT NULL,
    ShelfLifeDays  INT           NOT NULL,
    PRIMARY KEY (CompanyCode, ProductCode)
);

IF OBJECT_ID('stg.FxRate') IS NULL
CREATE TABLE stg.FxRate
(
    RateDate    DATE          NOT NULL,
    Currency    CHAR(3)       NOT NULL,
    UsdPerUnit  DECIMAL(18,6) NOT NULL,     -- dólares por 1 unidad de la moneda
    PRIMARY KEY (RateDate, Currency)
);

IF OBJECT_ID('stg.SalesLine') IS NULL
CREATE TABLE stg.SalesLine
(
    CompanyCode   VARCHAR(10)   NOT NULL,
    DocType       CHAR(3)       NOT NULL,   -- INV factura, CN nota de crédito
    DocNumber     VARCHAR(20)   NOT NULL,
    LineNumber    INT           NOT NULL,
    DocDate       DATE          NOT NULL,
    DocStatus     VARCHAR(10)   NOT NULL,   -- ACTIVE o CANCELLED
    CustomerCode  VARCHAR(20)   NOT NULL,
    ProductCode   VARCHAR(20)   NOT NULL,
    LotCode       VARCHAR(40)   NULL,
    Quantity      INT           NOT NULL,   -- siempre positiva en el archivo
    UnitPrice     DECIMAL(18,4) NOT NULL,   -- en la moneda del documento
    Currency      CHAR(3)       NOT NULL,
    LineCostUsd   DECIMAL(18,2) NOT NULL,
    RefDocNumber  VARCHAR(20)   NULL,       -- factura que corrige una nota de crédito
    PRIMARY KEY (CompanyCode, DocType, DocNumber, LineNumber)
);

IF OBJECT_ID('stg.LotSnapshot') IS NULL
CREATE TABLE stg.LotSnapshot
(
    SnapshotDate    DATE          NOT NULL,
    CompanyCode     VARCHAR(10)   NOT NULL,
    LotCode         VARCHAR(40)   NOT NULL,
    ProductCode     VARCHAR(20)   NOT NULL,
    WarehouseCode   VARCHAR(20)   NOT NULL,
    ProductionDate  DATE          NOT NULL,
    ExpiryDate      DATE          NOT NULL,
    QtyKg           DECIMAL(18,3) NOT NULL,
    PRIMARY KEY (SnapshotDate, CompanyCode, LotCode)
);

IF OBJECT_ID('stg.Shipment') IS NULL
CREATE TABLE stg.Shipment
(
    CompanyCode         VARCHAR(10)  NOT NULL,
    ShipmentNumber      VARCHAR(20)  NOT NULL,
    InvoiceNumber       VARCHAR(20)  NOT NULL,
    CustomerCode        VARCHAR(20)  NOT NULL,
    DestinationCountry  NVARCHAR(50) NOT NULL,
    ScheduledDate       DATE         NOT NULL,
    ActualShipDate      DATE         NULL,
    Status              VARCHAR(10)  NOT NULL,   -- PENDING, SHIPPED, CANCELLED
    Containers          INT          NOT NULL,
    PRIMARY KEY (CompanyCode, ShipmentNumber)
);

IF OBJECT_ID('stg.Receivable') IS NULL
CREATE TABLE stg.Receivable
(
    SnapshotDate   DATE          NOT NULL,
    CompanyCode    VARCHAR(10)   NOT NULL,
    DocNumber      VARCHAR(20)   NOT NULL,
    CustomerCode   VARCHAR(20)   NOT NULL,
    DocDate        DATE          NOT NULL,
    DueDate        DATE          NOT NULL,
    OpenAmountUsd  DECIMAL(18,2) NOT NULL,
    PRIMARY KEY (SnapshotDate, CompanyCode, DocNumber)
);
GO
