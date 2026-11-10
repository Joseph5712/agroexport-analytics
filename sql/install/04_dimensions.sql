-- AgroExport · 04 · Dimensiones
-- Una dimensión describe "quién, qué, cuándo". Cada una tiene una clave
-- sustituta (…Key, un entero interno) y la clave del negocio (…Code).
-- Clave importante del diseño: el mismo código de cliente o producto puede
-- existir en las dos sociedades, así que la sociedad forma parte de la
-- clave de negocio. C001 de CR01 y C001 de GT01 son clientes distintos.
-- Las dimensiones son SCD tipo 1: si cambia un nombre, se sobrescribe.

IF OBJECT_ID('dw.DimCompany') IS NULL
CREATE TABLE dw.DimCompany
(
    CompanyKey     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DimCompany PRIMARY KEY,
    CompanyCode    VARCHAR(10)   NOT NULL CONSTRAINT UQ_DimCompany_Code UNIQUE,
    CompanyName    NVARCHAR(100) NOT NULL,
    Country        NVARCHAR(50)  NOT NULL,
    LocalCurrency  CHAR(3)       NOT NULL
);

IF OBJECT_ID('dw.DimCustomer') IS NULL
CREATE TABLE dw.DimCustomer
(
    CustomerKey       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DimCustomer PRIMARY KEY,
    CompanyKey        INT           NOT NULL CONSTRAINT FK_DimCustomer_Company REFERENCES dw.DimCompany (CompanyKey),
    CustomerCode      VARCHAR(20)   NOT NULL,
    CustomerName      NVARCHAR(150) NOT NULL,
    Country           NVARCHAR(50)  NOT NULL,
    PaymentTermsDays  INT           NOT NULL,
    CONSTRAINT UQ_DimCustomer_BusinessKey UNIQUE (CompanyKey, CustomerCode)
);

IF OBJECT_ID('dw.DimProduct') IS NULL
CREATE TABLE dw.DimProduct
(
    ProductKey     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DimProduct PRIMARY KEY,
    CompanyKey     INT           NOT NULL CONSTRAINT FK_DimProduct_Company REFERENCES dw.DimCompany (CompanyKey),
    ProductCode    VARCHAR(20)   NOT NULL,
    ProductName    NVARCHAR(150) NOT NULL,
    Category       NVARCHAR(50)  NOT NULL,     -- Fresco / Procesado
    Subcategory    NVARCHAR(50)  NOT NULL,
    SalesUnit      NVARCHAR(20)  NOT NULL,     -- Caja / Tambor
    KgPerUnit      DECIMAL(9,3)  NOT NULL CONSTRAINT CK_DimProduct_Kg CHECK (KgPerUnit > 0),
    ShelfLifeDays  INT           NOT NULL,
    CONSTRAINT UQ_DimProduct_BusinessKey UNIQUE (CompanyKey, ProductCode)
);

-- Calendario: una fila por día. Se llena una sola vez con GENERATE_SERIES
-- (disponible desde SQL Server 2022).
IF OBJECT_ID('dw.DimDate') IS NULL
BEGIN
    CREATE TABLE dw.DimDate
    (
        DateKey      INT          NOT NULL CONSTRAINT PK_DimDate PRIMARY KEY,  -- AAAAMMDD
        [Date]       DATE         NOT NULL CONSTRAINT UQ_DimDate_Date UNIQUE,
        [Year]       SMALLINT     NOT NULL,
        [Quarter]    TINYINT      NOT NULL,
        [Month]      TINYINT      NOT NULL,
        MonthName    NVARCHAR(12) NOT NULL,
        YearMonth    CHAR(7)      NOT NULL,      -- 2026-10
        MonthStart   DATE         NOT NULL,
        [Day]        TINYINT      NOT NULL,
        IsoWeekday   TINYINT      NOT NULL       -- 1 lunes … 7 domingo
    );

    INSERT dw.DimDate (DateKey, [Date], [Year], [Quarter], [Month], MonthName, YearMonth, MonthStart, [Day], IsoWeekday)
    SELECT
        CONVERT(INT, FORMAT(d.[Date], 'yyyyMMdd')),
        d.[Date],
        YEAR(d.[Date]),
        DATEPART(QUARTER, d.[Date]),
        MONTH(d.[Date]),
        -- Nombres fijos en español, sin depender del idioma de la sesión.
        CHOOSE(MONTH(d.[Date]), N'Enero', N'Febrero', N'Marzo', N'Abril', N'Mayo', N'Junio',
               N'Julio', N'Agosto', N'Septiembre', N'Octubre', N'Noviembre', N'Diciembre'),
        FORMAT(d.[Date], 'yyyy-MM'),
        DATEFROMPARTS(YEAR(d.[Date]), MONTH(d.[Date]), 1),
        DAY(d.[Date]),
        -- (DATEDIFF desde un lunes conocido) evita depender de SET DATEFIRST.
        DATEDIFF(DAY, '19000101', d.[Date]) % 7 + 1
    FROM (SELECT DATEADD(DAY, s.value, CONVERT(DATE, '2024-01-01')) AS [Date]
          FROM GENERATE_SERIES(0, DATEDIFF(DAY, '2024-01-01', '2027-12-31')) AS s) AS d;
END;

-- Tipos de cambio diarios. USD no se guarda: su factor es 1.
IF OBJECT_ID('dw.FxRate') IS NULL
CREATE TABLE dw.FxRate
(
    RateDate    DATE          NOT NULL,
    Currency    CHAR(3)       NOT NULL,
    UsdPerUnit  DECIMAL(18,6) NOT NULL CONSTRAINT CK_FxRate_Positive CHECK (UsdPerUnit > 0),
    CONSTRAINT PK_FxRate PRIMARY KEY (RateDate, Currency)
);

-- Seguridad por sociedad para Power BI (RLS): qué usuario ve qué sociedad.
IF OBJECT_ID('dw.UserCompanyAccess') IS NULL
BEGIN
    CREATE TABLE dw.UserCompanyAccess
    (
        UserPrincipalName NVARCHAR(256) NOT NULL,
        CompanyCode       VARCHAR(10)   NOT NULL,
        CONSTRAINT PK_UserCompanyAccess PRIMARY KEY (UserPrincipalName, CompanyCode)
    );

    -- Usuarios de ejemplo. Cámbialos por correos reales al publicar en el servicio.
    INSERT dw.UserCompanyAccess (UserPrincipalName, CompanyCode) VALUES
        (N'gerencia@agroexport.demo', 'CR01'),
        (N'gerencia@agroexport.demo', 'GT01'),
        (N'planta.cr@agroexport.demo', 'CR01');
END;
GO
