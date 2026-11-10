// AgroExport · Power Query (M)
// 1. Inicio > Administrar parámetros > Nuevo:
//      ServerName    Texto   localhost        (o .\SQLEXPRESS, el mismo de VS Code)
//      DatabaseName  Texto   AgroExport
// 2. Inicio > Nuevo origen > Consulta en blanco > Editor avanzado, y pega una
//    consulta por tabla cambiando solo el nombre de la vista (Item).
// 3. Nombra cada consulta igual que la vista: DimCompany, DimCustomer, DimProduct,
//    DimDate, FactSales, FactLotSnapshot, FactShipment, FactReceivable,
//    SecurityAccess, LoadStatus, QualityAlerts.
//
// Leer de vistas (y no de tablas) permite que Power Query "doble" los pasos a
// SQL (query folding): el filtrado lo hace SQL Server, no tu PC.

let
    Origen = Sql.Database(ServerName, DatabaseName),
    Datos  = Origen{[Schema = "rpt", Item = "FactSales"]}[Data]
in
    Datos

// Ejemplo de un paso extra que se pliega a SQL: ventas desde 2025.
// let
//     Origen  = Sql.Database(ServerName, DatabaseName),
//     Datos   = Origen{[Schema = "rpt", Item = "FactSales"]}[Data],
//     Filtrar = Table.SelectRows(Datos, each [DateKey] >= 20250101)
// in
//     Filtrar
