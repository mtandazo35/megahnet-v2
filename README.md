# megahnet-v2

Version de trabajo de MEGAHNET para **rehacerlo sobre Debian con calma, sin tocar el
sistema que esta cobrando**.

El sistema nacio en XAMPP sobre Windows y se traslado a la nube a las prisas. Funciona,
pero quedaron costuras: temporizadores puestos a mano maquina por maquina, crons que
fallan en silencio, migraciones que pueden fallar sin que nadie se entere, codigo muerto
conviviendo con el vivo. Este repositorio es donde eso se arregla **sin prisa y sin
riesgo**, porque nada de lo que hay aqui esta cobrando a nadie.

- Sistema en produccion: `../megahnet` (siete inquilinos, VMs `172.22.22.11` … `.17`)
- Este repositorio: copia con **toda la historia** (399 commits heredados), mas las
  herramientas para levantarlo y probarlo en una maquina de pruebas.

## La regla que no se rompe

**Produccion no se toca desde aqui.** Ni un despliegue, ni una consulta de escritura, ni
un `git push`. Por eso el remoto que apunta al sistema actual se llama `base` y tiene el
envio deshabilitado a proposito: desde aqui se puede **traer** lo que se arregle alla,
nunca al reves por accidente.

```bash
git fetch base && git merge base/main    # traer arreglos hechos en produccion
```

Cuando algo de aqui este probado y se decida llevarlo al sistema real, se lleva **a
mano**, pieza a pieza, con el metodo de siempre: punto de retorno, prueba que falle con
el codigo anterior, revision adversarial y despliegue por etapas.

## Que hay, ademas del sistema

| Ruta | Que es |
|---|---|
| `installer/lib/temporizadores.sh` | Las siete tareas programadas, de una tabla unica. Hoy el instalador no crea ninguna |
| `installer/lib/migraciones.sh` | Aplica migraciones parando en seco al primer fallo, con registro y suma de verificacion |
| `installer/tests/` | Pruebas de esas piezas contra un cliente de base de datos simulado |
| `scripts/preflight.sh` | Comprueba si una maquina sirve **antes** de tocarla. Solo lectura |
| `scripts/anonimizar.sh` | Convierte un respaldo de produccion en una copia sin datos de clientes |
| `docs/etapas.md` | Las ocho etapas de revision, con lo que ya sabemos que falla en cada una |

## Por donde va

La revision es **por modulos**, y una etapa no se abre hasta cerrar la anterior con una
comprobacion que se pueda repetir. El detalle esta en [docs/etapas.md](docs/etapas.md);
se empieza por **instalacion y arranque**, porque es donde esta el fallo que el 1 de
octubre dejo a un inquilino sin facturar y nadie se entero.

Lo construido hasta ahora **no se ha probado nunca contra una base de datos real**: las
pruebas usan simuladores, que valen para la logica y no para la realidad. Esa validacion
es el primer trabajo en cuanto haya una maquina donde hacerla.
