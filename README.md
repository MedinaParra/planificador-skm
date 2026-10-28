# Planificador SKM — SolidCraft portable experimental

Repositorio **privado** de reconstrucción verificable: base pública SolidCraft
`7770f8982de8bf00cabfe421b7f563b34c7af90f` + delta acumulado hasta 05C + modo portable.
Las fuentes públicas se recuperan por ese commit exacto; los parches y hashes
permiten reconstruir y verificar el árbol completo sin guardar datos de usuarios.

**NO OPERATIVO / NOT_VALIDATED. RT750 NOT_VALIDATED.** No sustituye un plan de
izaje aprobado, tablas OEM verificadas ni revisión profesional. Las mediciones e
inspecciones geométricas no establecen capacidad, estabilidad o seguridad de izaje.

La distribución prevista es Windows x64, ZIP sin instalador, un `solidcraft.exe`
con sus licencias. No incluye CLI/MCP. El modo portable mantiene estado propio
junto al ejecutable y bloquea control remoto local, integraciones IA y updates.
No se crean claves ni certificados, no se alteran permisos o clientes externos.

El workflow sólo puede iniciarse manualmente. Usa un runner estándar Windows,
un único job serial limitado a 120 minutos, sin caché remoto ni despliegue/release.
Antes de iniciarlo se verifica cuota incluida y presupuesto de sobreconsumo $0.
No habilitar gasto ni cambiar a runners de pago. Artefactos privados con retención
corta; se entregan únicamente tras validar build, tests y QA gráfica del binario.

Hasta que un run concreto termine satisfactoriamente, este repositorio **no
demuestra** que exista un ejecutable validado. Consultar el resultado de Actions
y los recibos del mismo commit; las pruebas headless no son prueba de Windows GUI.

Licencia de SolidCraft y delta: MIT OR Apache-2.0, con NOTICE y licencias de
terceros conservadas desde la base. No contiene planos, CAD, credenciales ni
documentación interna del usuario.
