# Ampliaciones (diseño, no implementado)

Estas piezas completan la pila de la vacante, pero necesitan accesos que un entorno personal no tiene. Las dejo como **diseño documentado**, para que quede claro qué está hecho y qué no.

## SAP Business One / HANA como origen real

Hoy el generador hace de ERP. Para conectar un SAP Business One real, solo cambia el **extractor**: el contrato de archivos ([schemas.py](../agroexport/schemas.py)) y todo lo que viene después siguen igual.

| Archivo del contrato | Origen en SAP B1 (Service Layer, OData v4) | Validar en sandbox |
|---|---|---|
| `customers.csv` | `BusinessPartners` (`CardType = 'C'`) | Relación entre `CompanyDB` y la sociedad |
| `products.csv` | `Items` | Unidad de venta y kg por unidad |
| `sales_lines.csv` | `Invoices/DocumentLines` y `CreditNotes/DocumentLines` | `DocEntry` + `LineNum` como clave; moneda del importe; descuentos |
| `fx_rates.csv` | Tipos de cambio (`SBOBobService_GetCurrencyRate`) | La convención de `DocRate`: no asumir que es "USD por unidad" |
| `lot_snapshots.csv` | `BatchNumberDetails` y cantidades por almacén | Asignación de lotes a líneas |
| `receivables.csv` | Documentos abiertos (`DocumentStatus = 'bost_Open'`) | Saldos al corte oficial, sin aplicar créditos dos veces |

Reglas del extractor:
- Solo lectura. La plataforma analítica nunca crea facturas, pagos ni ajustes en SAP.
- Login, paginación con `$skip`/`$top` y Logout. Credenciales fuera del repositorio.
- Fijar el corte antes de paginar. Si alguien registra una factura mientras se pagina, la fotografía quedaría incompleta.
- La alternativa por HANA (`hdbcli`, consulta SQL directa) cubre el mismo alcance. Las dos rutas no se suman sin conciliar.

## Microsoft Fabric (Bronze / Silver / Gold)

| Capa | Equivalente actual | En Fabric |
|---|---|---|
| Bronze | `data/entregas` + manifiesto | Archivos originales en OneLake, con su huella |
| Silver | `validate.py` + staging | Notebook PySpark con las mismas reglas: tipos, claves, referencias y rechazos |
| Gold | `dw` + `rpt` | Tablas Delta con `batch_id`. Las vistas eligen solo una publicación terminada |

Detalle importante: en SQL Server, una transacción publica todo o nada. En Delta, cada tabla se escribe por separado, así que hace falta un **marcador de publicación** que se escribe al final, y las vistas solo leen lotes con marcador. Ese es el reto técnico a demostrar cuando haya una capacidad de Fabric disponible (por ejemplo, la prueba gratuita).

## Power Platform: seguimiento de alertas

Las alertas de `dq.CheckResult` se convierten en casos que una persona atiende:

- **Dataverse**: tabla de casos con estado `OPEN → ACKNOWLEDGED → RESOLVED`, responsable y comentario obligatorio para cambiar de estado.
- **Power Automate**: después de cada carga `Succeeded`, crea o actualiza casos por clave externa (`LoadBatchID + CheckCode`), sin duplicarlos.
- **Power Apps**: lista de casos filtrada por sociedad del usuario.
- **Concurrencia**: si dos personas editan el mismo caso, se rechaza la edición basada en una versión vieja.
- Licencias: el conector de SQL Server es Premium. Hay que revisarlo antes de comprometerse.

## Otras ampliaciones

- SCD tipo 2 en clientes (historial de cambios de nombre o condiciones de crédito).
- Tabla puente para una línea de venta repartida entre varios lotes.
- OTIF completo (requiere cantidad comprometida y fecha de entrega en destino).
- Orquestación programada (Airflow o el programador de tareas de Windows) con alertas por correo.
