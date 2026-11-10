-- AgroExport · 00 · Crear la base (solo para ejecución manual)
-- Ejecutar conectado a master. `python -m agroexport instalar` hace este paso
-- por su cuenta y omite este archivo.

IF DB_ID('AgroExport') IS NULL
    CREATE DATABASE AgroExport;
GO
