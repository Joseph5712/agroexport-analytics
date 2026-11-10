# Guía de Power BI

El reporte lo construyes tú en Power BI Desktop (es gratis). Esta guía tiene el orden exacto y los valores esperados para que compruebes que todo cuadra con SQL. Calcula unas 2 o 3 horas.

## 0. Antes de empezar

- La base `AgroExport` debe estar cargada con `python -m agroexport demo`.
- Guarda el reporte como proyecto: **Archivo > Guardar como > Proyecto de Power BI (.pbip)**, en `powerbi/AgroExport.pbip`. Si tu versión no muestra la opción, actívala en *Opciones > Características en versión preliminar*. El formato PBIP guarda el modelo en texto: Git ve los cambios y se puede revisar en un PR.

## 1. Cargar datos (Power Query)

1. Crea los parámetros `ServerName` y `DatabaseName` (ver [consultas.pq](../powerbi/consultas.pq)).
2. Crea una consulta por vista del esquema `rpt`: `DimCompany`, `DimCustomer`, `DimProduct`, `DimDate`, `FactSales`, `FactLotSnapshot`, `FactShipment`, `FactReceivable`, `SecurityAccess`, `LoadStatus` y `QualityAlerts`.
3. Modo de conexión: **Importar**.

> ¿Por qué vistas y no tablas? Las reglas (excluir anulados, días de atraso, tramos de antigüedad) se calculan una sola vez en SQL. DAX queda para lo que depende del filtro del usuario.

## 2. Modelo (vista de modelo)

**Marca `DimDate` como tabla de fechas** (columna `Date`). Sin esto, `SAMEPERIODLASTYEAR` no funciona bien.

Relaciones: todas son *uno a varios*, con **dirección de filtro única**, de la dimensión al hecho.

| Desde (1) | Hacia (*) |
|---|---|
| `DimDate[DateKey]` | `FactSales[DateKey]`, `FactLotSnapshot[SnapshotDateKey]`, `FactShipment[ScheduledDateKey]`, `FactReceivable[SnapshotDateKey]` |
| `DimCompany[CompanyKey]` | `FactSales`, `FactLotSnapshot`, `FactShipment`, `FactReceivable` |
| `DimCustomer[CustomerKey]` | `FactSales`, `FactShipment`, `FactReceivable` |
| `DimProduct[ProductKey]` | `FactSales`, `FactLotSnapshot` |

- **No relaciones** `DimCustomer` ni `DimProduct` con `DimCompany`. Crearías dos caminos de filtro hacia el mismo hecho (ambigüedad). Cada hecho recibe la sociedad directamente.
- `SecurityAccess`, `LoadStatus` y `QualityAlerts` quedan **sin relaciones**.
- Oculta las columnas `...Key` en la vista de informe. Al usuario solo le sirven los nombres.
- En `DimDate`, ordena `MonthName` por `Month` (*Ordenar por columna*).

## 3. Medidas

Copia las de [medidas.dax](../powerbi/medidas.dax) en una tabla llamada `Medidas`. La clave del modelo está en el inventario y la cartera: son **fotografías**, y la medida busca el último corte en vez de sumar todos los cortes.

## 4. Páginas

En todas: segmentación de **Sociedad** (`DimCompany[CompanyName]`) y de **Año/Mes**, más una tarjeta con la medida `Texto Corte`.

| Página | Elementos |
|---|---|
| **Resumen** | Tarjetas: Ventas Netas, Margen %, Variación Interanual %, Inventario Kg, Cartera Vencida, Puntualidad %. Gráfico de líneas: Ventas Netas y Ventas Año Anterior por mes. |
| **Comercial** | Barras: Ventas por `DimProduct[Subcategory]`. Matriz: cliente × mes con Ventas Netas y Margen %. Mapa o barras por `DimCustomer[Country]`. Tarjeta: Notas de Crédito %. |
| **Lotes y planta** | Barras apiladas: Inventario Kg por `FactLotSnapshot[ExpiryBucket]` y producto. Tabla: lotes con `DaysToExpiry` ≤ 30, ordenados por días. Tarjetas: Kg por Vencer 30 Días y Kg Vencidos con Existencia. |
| **Despachos** | Columnas: Puntualidad % por mes. Tabla: embarques pendientes atrasados. Tarjeta: Embarques Pendientes Atrasados. Histograma: `DaysLate`. |
| **Calidad y cobros** | Barras apiladas: Cartera Abierta por `AgingBucket` y cliente. Tabla de `LoadStatus` (estado de cada carga) y de `QualityAlerts` (alertas). |

## 5. Conciliación: Power BI contra SQL

Sin filtros, con los datos de `python -m agroexport demo`, deberías ver:

| Sociedad | Ventas Netas USD | Margen % | Inventario Kg (07/11/2026) | Cartera Abierta USD | Cartera Vencida USD | Puntualidad % |
|---|---:|---:|---:|---:|---:|---:|
| CR01 | 81,495,180.20 | 24.6 % | 1,085,364 | 8,355,371.95 | 3,472,875.27 | 81.4 % |
| GT01 | 73,168,540.29 | 24.6 % | 1,092,992 | 7,554,309.01 | 3,302,180.84 | 80.2 % |
| **Total** | **154,663,720.49** | | | | | |

La misma cifra desde SQL:

```sql
SELECT c.CompanyCode, SUM(f.NetAmountUsd) AS NetSalesUsd
FROM rpt.FactSales AS f
JOIN rpt.DimCompany AS c ON c.CompanyKey = f.CompanyKey
GROUP BY ROLLUP (c.CompanyCode);
```

Si un número no coincide, revisa en este orden: (1) DimDate marcada como tabla de fechas, (2) dirección de las relaciones, (3) la medida, comparando contra la consulta de [01_business_questions.sql](../sql/analysis/01_business_questions.sql).

## 6. Seguridad por sociedad (RLS)

Crea el rol `Sociedad` con los filtros de [rls.dax](../powerbi/rls.dax) y pruébalo con **Modelado > Ver como**:

| Usuario | Debe ver |
|---|---|
| `planta.cr@agroexport.demo` | Solo CR01 (Ventas Netas 81,495,180.20) |
| `gerencia@agroexport.demo` | CR01 y GT01 |
| Un correo sin asignación | Nada |

Toma una captura de cada caso para `docs/capturas/`.

## 7. Cierre

- [ ] Guardado como `.pbip` dentro de `powerbi/` y subido a Git
- [ ] Conciliación de la sección 5 comprobada
- [ ] RLS probado con los tres usuarios
- [ ] Capturas de las 5 páginas en `docs/capturas/`
