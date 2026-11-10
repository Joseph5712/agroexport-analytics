# Rendimiento: índice de cobertura en FactSalesLine

## Consulta

Ventas y costo por categoría y mes de un trimestre (julio a septiembre de 2026), desde `dw.FactSalesLine`. Es el tipo de consulta que hace Power BI al filtrar por fecha.

## Condiciones de la medición

| Concepto | Valor |
|---|---|
| Motor | SQL Server 2025 Express (RTM-CU10), contenedor Linux de desarrollo |
| Hardware | 4 vCPU, 15 GB de RAM |
| Datos | `generar --escala 10`: 94,299 líneas de venta |
| Caché | Caliente: los datos ya estaban en memoria (0 lecturas físicas en ambas corridas) |
| Repeticiones | 1 por plan, con `OPTION (RECOMPILE)` |
| Script | [02_performance.sql](../sql/analysis/02_performance.sql) |

## Resultados

| | Plan | Lecturas lógicas | Duración (Query Store) |
|---|---|---:|---:|
| Sin índice | Clustered Index Scan: recorre toda la tabla | 1,375 | 20.8 ms |
| Con `IX_FactSalesLine_Date_Cover` | Index Seek por `DateKey`, sin volver a la tabla | 75 | 11.1 ms |
| **Mejora** | | **−95 %** | **−47 %** |

## Interpretación

- Las **lecturas lógicas** son la métrica principal. No dependen de la carga del equipo en ese momento y crecen en proporción a los datos.
- El índice está ordenado por `DateKey` (el filtro del `WHERE`) e **incluye** las columnas que la consulta usa (`ProductKey`, `NetAmountUsd`, `CostAmountUsd`, `IsCancelled`). Por eso SQL Server no necesita volver a la tabla base: lo "cubre".
- La duración baja menos que las lecturas porque, con tan pocos datos, parte del tiempo es fijo (compilar y agrupar).
- **Costo del índice:** ocupa espacio y hace un poco más lentas las cargas, porque cada INSERT o UPDATE también lo mantiene. Para un almacén que se carga una vez por día y se consulta todo el día, compensa.

## Tu medición

Repite el script en tu PC y anota tus valores aquí. Los números absolutos cambiarán, pero la proporción debería ser parecida.

| Fecha | Equipo | Líneas | Lecturas sin índice | Lecturas con índice | ms sin | ms con |
|---|---|---:|---:|---:|---:|---:|
| | | | | | | |
