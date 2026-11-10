# Guía de entrevista

Primero el guion de demostración, después preguntas probables con respuestas **en tus palabras**. Practícalas en voz alta. Si no puedes explicar una, abre el archivo indicado y vuelve a leerlo.

## Guion de demo (5 minutos)

1. **El problema (30 s).** "Una agroexportadora con dos sociedades no confía en sus números: cada área tiene su hoja de Excel. Construí la canalización que va del ERP al reporte, con números conciliados y trazables."
2. **La arquitectura (45 s).** Muestra el diagrama de [diseno.md](diseno.md): archivos con manifiesto → Python valida → una transacción publica en SQL Server → vistas → Power BI.
3. **La recuperación (90 s).** Ejecuta `python -m agroexport demo` y comenta cada paso:
   - "Primero simulo un fallo después de publicar: hay ROLLBACK y el almacén queda vacío."
   - "Reintento: se publica, rechaza 8 filas con su motivo y descarta un duplicado."
   - "Cargo el mismo paquete otra vez: se salta, porque la huella ya está publicada."
   - "Llega la entrega incremental con una anulación de octubre y un cliente renombrado."
4. **La conciliación (45 s).** `SELECT * FROM dq.Reconciliation`: "Cuento y sumo por dos caminos. Si un JOIN perdiera o duplicara filas, la carga se revierte."
5. **El reporte (60 s).** Página Resumen, cambia de sociedad y muestra RLS con *Ver como* `planta.cr@agroexport.demo`.
6. **Cierre (30 s).** Una decisión técnica y un límite: "El inventario es semiaditivo, por eso la medida busca el último corte. Un límite: una línea de venta solo referencia un lote. Repartirla entre varios lotes requiere una tabla puente."

## Preguntas de diseño

**¿Por qué un modelo estrella y no las tablas tal como vienen del ERP?**
Las tablas del ERP están hechas para registrar operaciones. Para analizar necesito pocas uniones, claves enteras y una granularidad clara. En la estrella, cada hecho se une directamente con sus dimensiones y Power BI filtra en una sola dirección.

**¿Qué significa granularidad y cuál es la de tus hechos?**
Es lo que representa una fila. En ventas, una línea de documento. En inventario, un lote en una fecha de corte. Lo decido antes de crear la tabla, porque si mezclo granularidades sumo cosas que no se pueden sumar. → [diseno.md](diseno.md#granularidad-qué-representa-una-fila)

**¿Por qué la sociedad es parte de la clave del cliente?**
Porque `C001` existe en las dos sociedades y son clientes distintos. Si la clave fuera solo `C001`, uniría ventas de dos clientes diferentes. → [04_dimensions.sql](../sql/install/04_dimensions.sql)

**¿Qué es un hecho semiaditivo?**
Uno que se puede sumar en algunas dimensiones pero no en el tiempo. El inventario de dos lotes el mismo día se suma; el de enero más el de febrero no significa nada. Por eso la medida DAX busca el último corte. → [medidas.dax](../powerbi/medidas.dax)

**¿Por qué guardas las notas de crédito con signo negativo?**
Para que `SUM()` dé ventas netas sin lógica extra en cada consulta. El archivo trae la cantidad positiva y el tipo de documento; el signo lo aplico al publicar.

**¿Por qué no usaste FLOAT para los importes?**
`FLOAT` no representa centavos exactos: 0.1 + 0.2 no da 0.3. La conciliación compararía números que difieren en la última cifra. Uso `DECIMAL(18,2)` y redondeo por línea.

## Preguntas de ETL y fallos

**¿Qué pasa si tu proceso falla a la mitad?**
Toda la publicación ocurre en una transacción. Si algo falla, Python hace ROLLBACK y el almacén queda como estaba. El fallo se registra en otra conexión, porque si lo escribiera en la misma transacción, el ROLLBACK lo borraría. Tengo una prueba que lo demuestra. → [pipeline.py](../agroexport/pipeline.py), `test_failure_rolls_back_everything`

**¿Qué es idempotencia y cómo la garantizas?**
Que ejecutar algo dos veces deja el mismo resultado que una vez. Calculo una huella SHA-256 de todos los archivos. Si ese paquete ya está `Succeeded`, la carga se marca `Skipped`. Además, un índice único filtrado impide que la base acepte dos `Succeeded` del mismo paquete, aunque el código fallara.

**¿Y si dos personas lanzan la carga al mismo tiempo?**
Tomo un candado de aplicación (`sp_getapplock`) exclusivo dentro de la transacción y reviso si el paquete ya se publicó *después* de tenerlo. Así solo una carga puede pasar. Lo pruebo con dos hilos: una termina `Succeeded` y la otra `Skipped`. → `test_concurrent_loads_publish_once`

**¿Cómo tratas los datos malos?**
Separo dos casos. Si un archivo no tiene las columnas del contrato, detengo todo porque no lo puedo interpretar. Si una fila tiene un error (fecha imposible, cliente inexistente), la rechazo con su motivo y su contenido original en `dq.RejectedRow` y sigo con las demás.

**¿Qué haces con los duplicados?**
Si son idénticos, conservo uno y lo cuento. Si tienen la misma clave pero datos distintos, no sé cuál es el correcto, así que rechazo todas las versiones para que alguien decida.

**¿Cómo manejas una corrección o una anulación que llega después?**
Llega con la misma clave de negocio. En ventas hago upsert: la fila se actualiza y queda marcada con el lote que la cambió. En las fotografías reemplazo el corte completo, porque con un upsert un lote eliminado en la corrección quedaría como fila vieja.

**¿Qué es la conciliación y por qué la necesitas?**
Comparar el origen contra el destino por dos caminos independientes: cantidad de filas e importe total. Si un JOIN pierde filas (falta un cliente) o las multiplica (un tipo de cambio duplicado), los números no cuadran y la carga se revierte. Las pruebas además comparan el total de SQL con un cálculo hecho en Python.

**¿Por qué UPDATE + INSERT y no MERGE?**
Es más fácil de leer y de depurar, y `MERGE` tiene problemas conocidos con concurrencia que exigen pistas de bloqueo adicionales.

## La historia del bug (buena para "cuéntame un problema que resolviste")

> "La demo se quedaba colgada en la segunda carga. Revisé `sys.dm_exec_requests` y vi que la publicación esperaba un bloqueo (`LCK_M_S`) de la conexión de auditoría. Esa conexión tenía `open_transaction_count = 1` aunque la había abierto con autocommit. Hice una prueba mínima y confirmé que el *pool* de conexiones de ODBC reutilizaba una conexión que antes había estado en modo transacción, y conservaba la transacción implícita. Desactivé el pool, documenté la causa en el código y las pruebas de concurrencia pasaron."

Muestra método: observar (DMV), formular una hipótesis, reproducirla con un caso mínimo, corregir y verificar. → [db.py](../agroexport/db.py)

## Preguntas de SQL

**¿Cómo investigas una consulta lenta?**
Activo `SET STATISTICS IO, TIME ON` y el plan de ejecución real. Miro lecturas lógicas, no solo el tiempo, porque las lecturas no dependen de la carga del servidor. Busco *scans* donde esperaría *seeks*. Pruebo un índice y vuelvo a medir. Con Query Store comparo los planes antes y después. En este proyecto bajé de 1,375 a 75 lecturas. → [rendimiento.md](rendimiento.md)

**¿Qué es un índice de cobertura?**
Un índice que contiene todas las columnas que la consulta necesita (en la clave o en `INCLUDE`), así SQL Server no tiene que volver a la tabla. Su costo: espacio y cargas un poco más lentas.

**¿Por qué comparar contra el año anterior con un JOIN y no con `LAG(…, 12)`?**
`LAG` cuenta filas, no meses. Si un mes no tuviera ventas, `LAG(12)` compararía contra el mes equivocado. El JOIN por `DATEADD(YEAR, -1, mes)` siempre compara el mes correcto. → [01_business_questions.sql](../sql/analysis/01_business_questions.sql)

**¿Diferencia entre `RANK`, `DENSE_RANK` y `ROW_NUMBER`?**
`ROW_NUMBER` da números únicos aunque haya empates. `RANK` repite el puesto en un empate y salta el siguiente (1, 1, 3). `DENSE_RANK` lo repite sin saltar (1, 1, 2). Para un "top 5 productos" uso `DENSE_RANK`, porque un empate no debe dejar fuera a nadie.

## Preguntas de Power BI

**¿Por qué Power BI lee vistas y no tablas?**
Las reglas (excluir anulados, tramos de antigüedad) se definen una vez en SQL y valen igual para el reporte y para cualquier consulta. Si cambia el almacén, ajusto la vista y el reporte no se rompe.

**¿Por qué no relacionaste DimCustomer con DimCompany?**
Habría dos caminos de filtro de la sociedad hacia ventas: directo y a través del cliente. Eso genera ambigüedad. Cada hecho recibe la sociedad directamente.

**¿Cómo funciona tu seguridad por filas?**
Una tabla asigna correos a sociedades. El rol filtra `DimCompany` con `USERPRINCIPALNAME()`, y el filtro baja a los hechos por las relaciones. También filtro clientes y productos para que no se vean nombres de la otra sociedad. Un usuario sin asignación ve cero filas. → [rls.dax](../powerbi/rls.dax)

**¿Cómo sabes que el reporte muestra el número correcto?**
Comparo cada tarjeta contra una consulta SQL sobre las mismas vistas. Los valores esperados están en [power_bi.md](power_bi.md#5-conciliación-power-bi-contra-sql).

## Preguntas incómodas (responde con honestidad)

**¿Usaste SAP o Fabric de verdad?**
"No. Diseñé cómo se conectarían y documenté el mapeo y los puntos a validar, pero no tuve acceso a un SAP ni a una capacidad de Fabric. Lo que sí está hecho y probado es SQL Server, Python y Power BI." → [ampliaciones.md](ampliaciones.md)

**¿Usaste IA?**
"Sí, como asistente, igual que uso documentación. Las decisiones las puedo explicar y defender, y las pruebas demuestran que el sistema hace lo que digo." Esta respuesta solo funciona si de verdad puedes explicar todo lo anterior.

**¿Qué mejorarías?**
SCD tipo 2 para conservar el historial de clientes, una tabla puente lote-línea, OTIF completo y orquestación programada con alertas.
